import XCTest
@testable import FlyCommander
import TCCore

final class SMBConnectionConfigTests: XCTestCase {
    func testRecordIdentityAndNoSecretInJSON() throws {
        let r = SMBConnectionRecord(server: "truenas", share: "downloads",
                                    domain: "WORKGROUP", username: "shaogaoyang",
                                    remembers: true)
        let decoded = try JSONDecoder().decode(SMBConnectionRecord.self,
                                               from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded, r)
        XCTAssertEqual(r.sourceID, "smb://truenas/downloads")
        XCTAssertEqual(r.credentialAccount, "truenas|WORKGROUP|downloads|shaogaoyang")
        // 无域 → domain 段空串
        let noDom = SMBConnectionRecord(server: "h", share: "s", domain: nil, username: "u")
        XCTAssertEqual(noDom.credentialAccount, "h||s|u")
        XCTAssertEqual(noDom.sourceID, "smb://h/s")
        // record/config 序列化不含密码
        let json = String(data: try JSONEncoder().encode(r), encoding: .utf8)!
        XCTAssertFalse(json.contains("pass"))
    }
    func testConfigMatchesRecordIdentity() {
        let r = SMBConnectionRecord(server: "h", share: "s", domain: nil, username: "u")
        let c = r.config()
        XCTAssertEqual(c.sourceID, r.sourceID)
        XCTAssertEqual(c.credentialAccount, r.credentialAccount)
    }
    func testRequestBuildsRecordAndConfig() {
        let req = SMBConnectionRequest(server: "h", share: "s", domain: nil,
                                       username: "u", secret: "pw", remember: true)
        // record 每次构建自带新 UUID id（保存语义下 id 由 save 赋稳定值）→ 逐参数比对
        XCTAssertEqual(req.record.sourceID, r2(server: "h").sourceID)
        XCTAssertEqual(req.record.credentialAccount, r2(server: "h").credentialAccount)
        XCTAssertFalse(req.record.id.isEmpty)
        XCTAssertEqual(req.config.sourceID, "smb://h/s")
        XCTAssertEqual(req.record.remembers, true)
    }
    private func r2(server: String) -> SMBConnectionRecord {
        SMBConnectionRecord(server: "h", share: "s", domain: nil, username: "u", remembers: true)
    }
}
