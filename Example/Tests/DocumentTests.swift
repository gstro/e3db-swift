import UIKit
import XCTest

@testable import E3db

let type1 = "type1"
let type2 = "type2"

class DocumentTests: XCTestCase, TestUtils {

    var client1: Client?
    var config1: Config?

    var client2: Client?
    var config2: Config?

    private func createWriterKey(client: Client, type: String) -> EAKInfo {
        var eakInfo: EAKInfo?
        asyncTest("createWriterKey") { (expect) in
            client.createWriterKey(type: type) { (result) in
                defer { expect.fulfill() }
                guard case .success(let eak) = result else {
                    return XCTFail()
                }
                eakInfo = eak
            }
        }
        return eakInfo!
    }

    override func setUp() {
        super.setUp()

        let (c1, cfg1) = clientWithConfig()
        let (c2, cfg2) = clientWithConfig()
        (client1, config1) = (c1, cfg1)
        (client2, config2) = (c2, cfg2)
    }

    func testCanStoreAndRetrieveEAKInfo() {
        let eakInfo = createWriterKey(client: client1!, type: type1)

        do {
            // serialize
            let serialized = try JSONEncoder().encode(eakInfo)

            // store and retrieve in user defaults
            let defaultsKey = "eak"
            let defaults    = UserDefaults.standard

            defaults.set(serialized, forKey: defaultsKey)
            guard let retrieved = (defaults.value(forKey: defaultsKey) as? Data) else {
                return XCTFail("Could not retrieve eak data from defaults")
            }

            // deserialize into eak
            let deserialized = try JSONDecoder().decode(EAKInfo.self, from: retrieved)

            // compare that they are the same
            XCTAssertEqual(eakInfo, deserialized)
        } catch {
            XCTFail(error.localizedDescription)
        }
    }

    func testCanShareEAK() {
        let test = #function + UUID().uuidString
        var eakInfo1: EAKInfo?

        asyncTest(test + "createWriterKey") { (expect) in
            self.client1!.createWriterKey(type: type1) { (result) in
                defer { expect.fulfill() }
                guard case .success(let eak1) = result else {
                    return XCTFail()
                }
                eakInfo1 = eak1
            }
        }
        XCTAssertNotNil(eakInfo1)

        asyncTest(test + "share") { (expect) in
            self.client1!.share(type: type1, readerId: self.config2!.clientId) { (result) in
                defer { expect.fulfill() }
                guard case .success = result else {
                    return XCTFail()
                }
            }
        }

        asyncTest(test + "getReaderKey") { (expect) in
            self.client1!.getReaderKey(writerId: self.config1!.clientId, userId: self.config1!.clientId, type: type1) { (result) in
                defer { expect.fulfill() }
                guard case .success(let eakInfo2) = result else {
                    return XCTFail()
                }
                XCTAssert(eakInfo1!.eak == eakInfo2.eak)
            }
        }
    }

    func testCanEncryptAndDecryptDoc() {
        let eakInfo = createWriterKey(client: client1!, type: type1)

        do {
            let testData = ["test": "data"]
            let encrypted = try client1!.encrypt(type: type1, data: RecordData(cleartext: testData), eakInfo: eakInfo)
            XCTAssert(encrypted.clientMeta.writerId == config1!.clientId)

            let decrypted = try client1!.decrypt(encryptedDoc: encrypted, eakInfo: eakInfo)
            XCTAssert(decrypted.clientMeta.writerId == config1!.clientId)
            XCTAssertEqual(decrypted.data, testData)
        } catch {
            XCTFail(error.localizedDescription)
        }
    }

    func testCanEncryptForOtherClient() {
        let eakInfo1 = createWriterKey(client: client1!, type: type1)
        var eakInfo2: EAKInfo?
        asyncTest("share") { (expect) in
            self.client1!.share(type: type1, readerId: self.config2!.clientId) { (result) in
                defer { expect.fulfill() }
                guard case .success = result else {
                    return XCTFail()
                }
            }
        }
        asyncTest("getReaderKey") { (expect) in
            self.client2!.getReaderKey(writerId: self.config1!.clientId, userId: self.config1!.clientId, type: type1) { (result) in
                defer { expect.fulfill() }
                guard case .success(let eak2) = result else {
                    return XCTFail()
                }
                eakInfo2 = eak2
            }
        }
        XCTAssertNotNil(eakInfo2)

        do {
            let testData = ["test": "data"]
            let encrypted = try client1!.encrypt(type: type1, data: RecordData(cleartext: testData), eakInfo: eakInfo1)
            XCTAssert(encrypted.clientMeta.writerId == config1!.clientId)

            let decrypted = try client2!.decrypt(encryptedDoc: encrypted, eakInfo: eakInfo2!)
            XCTAssert(decrypted.clientMeta.writerId == config1!.clientId)
            XCTAssertEqual(decrypted.data, testData)
        } catch {
            XCTFail(error.localizedDescription)
        }
    }

    func testEncryptWithMismatchedEAKInfoFailsWithError() {
        let eakInfo = createWriterKey(client: client1!, type: type1)
        XCTAssertThrowsError(try client2!.encrypt(type: type1, data: RecordData(cleartext: ["test": "data"]), eakInfo: eakInfo), "failed to throw error") { (error) in
            guard case E3dbError.cryptoError(let msg) = error else {
                return XCTFail("Threw other error: \(error.localizedDescription)")
            }
            XCTAssert(msg.count > 0)
        }
    }

    func testDecryptFailure() {
        let eakInfo1 = createWriterKey(client: client1!, type: type1)
        let eakInfo2 = createWriterKey(client: client1!, type: type2)
        do {
            let testData = ["test": "data"]
            let encrypted = try client1!.encrypt(type: type1, data: RecordData(cleartext: testData), eakInfo: eakInfo1)
            XCTAssert(encrypted.clientMeta.writerId == config1!.clientId)

            // wrong eakInfo
            let decrypted = try client1!.decrypt(encryptedDoc: encrypted, eakInfo: eakInfo2)
            XCTFail("Decryption should not have succeeded: \(decrypted)")
        } catch E3dbError.cryptoError(let msg) {
            XCTAssert(msg == "Failed to decrypt value")
        } catch {
            XCTFail("Threw other error: \(error.localizedDescription)")
        }
    }

    func testCanSignVerifyEncryptedDoc() {
        let eakInfo = createWriterKey(client: client1!, type: type1)
        do {
            let testData = ["test": "data"]
            let encrypted = try client1!.encrypt(type: type1, data: RecordData(cleartext: testData), eakInfo: eakInfo)
            XCTAssert(encrypted.clientMeta.writerId == config1!.clientId)

            let signed = try client1!.sign(document: encrypted)
            XCTAssertEqual(encrypted.encryptedData, signed.document.encryptedData)

            XCTAssert(try client1!.verify(signed: signed, pubSigKey: config1!.publicSigKey))
        } catch {
            XCTFail("Threw error: \(error.localizedDescription)")
        }
    }

    func testCanSignVerifySignedDoc() {
        let eakInfo = createWriterKey(client: client1!, type: type1)
        do {
            let testData = ["test": "data"]
            let encrypted = try client1!.encrypt(type: type1, data: RecordData(cleartext: testData), eakInfo: eakInfo)
            XCTAssert(encrypted.clientMeta.writerId == config1!.clientId)

            // sign once
            let signed1 = try client1!.sign(document: encrypted)
            XCTAssertEqual(encrypted.encryptedData, signed1.document.encryptedData)

            // sign again
            let signed2 = try client1!.sign(document: signed1)
            XCTAssertEqual(signed1.document.encryptedData, signed2.document.document.encryptedData)

            // create signed doc manually
            let doc = SignedDocument(document: signed1, signature: signed2.signature)

            // verify outer layer
            XCTAssert(try client1!.verify(signed: doc, pubSigKey: config1!.publicSigKey))
        } catch {
            XCTFail("Threw error: \(error.localizedDescription)")
        }
    }

    func testCanSignVerifyCustomSignable() {
        struct CustomSignableType: Signable {
            let num: Int
            let arr: [String]

            func serialized() -> String {
                return "\(num)" + arr.joined()
            }
        }
        do {
            let custom = CustomSignableType.init(num: 5, arr: ["test1", "test2", "test3"])
            let signed = try client1!.sign(document: custom)
            XCTAssertEqual(custom.arr, signed.document.arr)
            XCTAssert(try client1!.verify(signed: signed, pubSigKey: config1!.publicSigKey))
        } catch {
            XCTFail("Threw error: \(error.localizedDescription)")
        }
    }

    func testCanSignAndOtherClientVerify() {
        let eakInfo = createWriterKey(client: client1!, type: type1)
        do {
            let testData = ["test": "data"]
            let encrypted = try client1!.encrypt(type: type1, data: RecordData(cleartext: testData), eakInfo: eakInfo)
            XCTAssert(encrypted.clientMeta.writerId == config1!.clientId)

            let signed = try client1!.sign(document: encrypted)
            XCTAssertEqual(encrypted.encryptedData, signed.document.encryptedData)

            // other client
            XCTAssert(try client2!.verify(signed: signed, pubSigKey: config1!.publicSigKey))
        } catch {
            XCTFail("Threw error: \(error.localizedDescription)")
        }
    }

    func testVerificationFailure() {
        let eakInfo = createWriterKey(client: client1!, type: type1)
        do {
            let testData = ["test": "data"]
            let encrypted = try client1!.encrypt(type: type1, data: RecordData(cleartext: testData), eakInfo: eakInfo)
            XCTAssert(encrypted.clientMeta.writerId == config1!.clientId)

            let signed = try client1!.sign(document: encrypted)
            XCTAssertEqual(encrypted.encryptedData, signed.document.encryptedData)

            // modify signature
            let doc = SignedDocument(document: signed, signature: signed.signature + "bad")
            XCTAssertThrowsError(try client1!.verify(signed: doc, pubSigKey: config1!.publicSigKey))
        } catch {
            XCTFail("Threw other error: \(error.localizedDescription)")
        }
    }

    func testVerificationFailureOtherKey() {
        let eakInfo = createWriterKey(client: client1!, type: type1)
        do {
            let testData = ["test": "data"]
            let encrypted = try client1!.encrypt(type: type1, data: RecordData(cleartext: testData), eakInfo: eakInfo)
            XCTAssert(encrypted.clientMeta.writerId == config1!.clientId)

            let signed = try client1!.sign(document: encrypted)
            XCTAssertEqual(encrypted.encryptedData, signed.document.encryptedData)

            // use other client key
            let verified = try client1!.verify(signed: signed, pubSigKey: config2!.publicSigKey)
            XCTAssertFalse(verified)
        } catch {
            XCTFail("Threw other error: \(error.localizedDescription)")
        }
    }

    func testSignedEncryptedCodability() {
        let eakInfo = createWriterKey(client: client1!, type: type1)
        do {
            let testData  = ["test": "data"]
            let encrypted = try client1!.encrypt(type: type1, data: RecordData(cleartext: testData), eakInfo: eakInfo)
            let signed    = try client1!.sign(document: encrypted)

            let encoder = JSONEncoder()
            let encoded = try encoder.encode(signed)

            let decoder = JSONDecoder()
            let decoded = try decoder.decode(SignedDocument<EncryptedDocument>.self, from: encoded)

            // encoding / decoding round trip was successful
            XCTAssertEqual(encrypted.encryptedData, decoded.document.encryptedData)

            // round trip did not modify
            let verified = try client1!.verify(signed: decoded, pubSigKey: config1!.publicSigKey)
            XCTAssert(verified)
        } catch {
            XCTFail("Threw error: \(error.localizedDescription)")
        }
    }

    func testExternalVerification() {
        // shared with e3db-js SDK
        let document = """
{"doc":{"data":{"test_field":"QWfE7PpAjTgih1E9jyqSGex32ouzu1iF3la8fWNO5wPp48U2F5Q6kK41_8hgymWn.HW-dBzttfU6Xui-o01lOdVqchXJXqfqQ.eo8zE8peRC9qSt2ZOE8_54kOF0bWBEovuZ4.zO56Or0Pu2IFSzQZRpuXLeinTHQl7g9-"},"meta":{"plain":{"client_pub_sig_key":"fcyEKo6HSZo9iebWAQnEemVfqpTUzzR0VNBqgJJG-LY","server_sig_of_client_sig_key":"ZtmkUb6MJ-1LqpIbJadYl_PPH5JjHXKrBspprhzaD8rKM4ejGD8cJsSFO1DlR-r7u-DKsLUk82EJF65RnTmMDQ"},"type":"ticket","user_id":"d405a1ce-e528-4946-8682-4c2369a26604","writer_id":"d405a1ce-e528-4946-8682-4c2369a26604"},"rec_sig":"YsNbSXy0mVqsvgArmdESe6SkTAWFui8_NBn8ZRyxBfQHmJt7kwDU6szEqiRIaoZGrHsqgwS3uduLo_kzG6UeCA"},"sig":"iYc7G6ersNurZRr7_lWqoilr8Ve1d6HPZPPyC4YMXSvg7QvpUAHvjv4LsdMMDthk7vsVpoR0LYPC_SkIip7XCw"}
"""
        do {
            let signedDoc = try JSONDecoder().decode(SignedDocument<EncryptedDocument>.self, from: Data(document.utf8))
            let verified  = try client1?.verify(signed: signedDoc, pubSigKey: (signedDoc.document.clientMeta.plain?["client_pub_sig_key"])!)
            XCTAssert(verified ?? false)
        } catch {
            XCTFail(error.localizedDescription)
        }
    }

    func testBlnsSerializationSwiftMatchesJavaScript() {
        let swiftTests = serializeBlns()
        let nodeTests  = loadBlnsSerializationResults(filename: "blns-node")

        // known indexes for tests that fail based on known issues
        // 96 and 169 have hidden-whitespace related errors
        let knownFailures = ["96", "169"]
        let failedTests = zip(swiftTests, nodeTests)
            .filter { $0.0["serialized"] != $0.1["serialized"] }
            .filter { !knownFailures.contains($0.0["index"]!) }

        XCTAssert(failedTests.isEmpty)
    }

    func testBlnsSerializationSwiftMatchesJava() {
        let swiftTests = serializeBlns()
        let javaTests  = loadBlnsSerializationResults(filename: "blns-java")

        // known indexes for tests that fail based on known issues
        // 96 and 169 have hidden-whitespace related errors
        // 92, 94, 503, 504 have unicode case-sensitivity related errors
        let knownFailures = ["92", "94", "96", "169", "503", "504"]
        let failedTests = zip(swiftTests, javaTests)
            .filter { $0.0["serialized"] != $0.1["serialized"] }
            .filter { !knownFailures.contains($0.0["index"]!) }

        XCTAssert(failedTests.isEmpty)
    }

}
