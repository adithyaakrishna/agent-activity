import Darwin
import Darwin.C
import Foundation

public struct HookRecordStore {
  public static let defaultMaxBytes = 26_214_400

  private let maxBytes: Int

  public init(maxBytes: Int = HookRecordStore.defaultMaxBytes) {
    self.maxBytes = max(1, maxBytes)
  }

  public func append(_ record: [String: Any], provider: HookProvider, directory: URL) throws {
    var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    line.append(0x0A)
    guard line.count <= maxBytes else {
      throw POSIXError(.EFBIG)
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let lockURL = directory.appendingPathComponent(".\(provider.rawValue).lock")
    let lockDescriptor = try openFile(at: lockURL, flags: O_RDWR | O_CREAT)
    defer { Darwin.close(lockDescriptor) }
    guard flock(lockDescriptor, LOCK_EX) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { flock(lockDescriptor, LOCK_UN) }

    let recordURL = directory.appendingPathComponent("\(provider.rawValue).jsonl")
    var recordDescriptor = try openFile(at: recordURL, flags: O_WRONLY | O_APPEND | O_CREAT)
    defer {
      if recordDescriptor >= 0 {
        Darwin.close(recordDescriptor)
      }
    }

    var information = stat()
    guard Darwin.fstat(recordDescriptor, &information) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if information.st_size > 0, information.st_size + off_t(line.count) > off_t(maxBytes) {
      Darwin.close(recordDescriptor)
      recordDescriptor = -1
      try rotate(recordURL)
      recordDescriptor = try openFile(at: recordURL, flags: O_WRONLY | O_APPEND | O_CREAT)
    }

    try writeAll(line, to: recordDescriptor)
  }

  private func rotate(_ recordURL: URL) throws {
    let backupURL = recordURL.appendingPathExtension("1")
    if Darwin.unlink(backupURL.path) != 0, errno != ENOENT {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard Darwin.rename(recordURL.path, backupURL.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func openFile(at url: URL, flags: Int32) throws -> Int32 {
    let descriptor = Darwin.open(url.path, flags, mode_t(0o600))
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard var address = bytes.baseAddress else { return }
      var remaining = bytes.count
      while remaining > 0 {
        let written = Darwin.write(descriptor, address, remaining)
        guard written > 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        remaining -= written
        address = address.advanced(by: written)
      }
    }
  }
}
