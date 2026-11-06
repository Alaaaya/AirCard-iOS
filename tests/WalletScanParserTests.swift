import XCTest
import AirliftFFI
@testable import Mirsa

final class WalletScanParserTests: XCTestCase {

    func testPaymentNetworkFromAID() {
        XCTAssertEqual(PaymentNetwork.fromAID("A0000000031010"), .visa)
        XCTAssertEqual(PaymentNetwork.fromAID("A0000000041010"), .mastercard)
        XCTAssertEqual(PaymentNetwork.fromAID("A000000025010801"), .amex)
        XCTAssertEqual(PaymentNetwork.fromAID("A000000333010101"), .unionPay)
        XCTAssertEqual(PaymentNetwork.fromAID("A0000001523010"), .discover)
        XCTAssertEqual(PaymentNetwork.fromAID("A0000000651010"), .jcb)
        XCTAssertNil(PaymentNetwork.fromAID("B1234567890123"))
    }

    func testCardIDsExtractionFromDashboardLoading() {
        let line = "Dashboard loading primary card: for CARD_TEST_HASH_1234567890123="
        let ids = WalletScanParser.cardIDs(in: line)
        XCTAssertEqual(ids, ["CARD_TEST_HASH_1234567890123="])
    }

    func testCardIDsExtractionFromInSessionAndGlobal() {
        let lineGlobal = #"nfcd[123]: passIDs[global] = ( "CARD_TEST_HASH_1234567890123=" )"#
        let idsGlobal = WalletScanParser.cardIDs(in: lineGlobal)
        XCTAssertEqual(idsGlobal, ["CARD_TEST_HASH_1234567890123="])

        let lineSession = #"nfcd[123]: passIDs[InSession]: ( "abc123def456abc123def456" )"#
        let idsSession = WalletScanParser.cardIDs(in: lineSession)
        XCTAssertEqual(idsSession, ["abc123def456abc123def456"])
    }

    func testCardIDsExtractionFromPath() {
        let line = "/var/mobile/Library/Passes/Cards/CARD_TEST_HASH_1234567890123=.pkpass/preview.png"
        let ids = WalletScanParser.cardIDs(in: line)
        XCTAssertTrue(ids.contains("CARD_TEST_HASH_1234567890123="))
    }

    func testCardIDsExtractionFromWritingCard() {
        let line = "PDCardFileManager: writing card CARD_TEST_HASH_1234567890123= to disk"
        let ids = WalletScanParser.cardIDs(in: line)
        XCTAssertTrue(ids.contains("CARD_TEST_HASH_1234567890123="))
    }

    func testPlaceholderFiltering() {
        let dummyLine = "Dashboard loading for OM6NYhwXMZrAw0sRUjR62wmF4ZQ= and hwAtAmHKYwsQrJbT5cTNDsaxVME="
        let ids = WalletScanParser.cardIDs(in: dummyLine)
        XCTAssertTrue(ids.isEmpty, "Known placeholder hashes must be filtered out")
    }

    func testActivationIDsExtraction() {
        let line = #"Stockholm: activating payment pass ID: CARD_TEST_HASH_1234567890123= AID: A0000000031010"#
        let activations = WalletScanParser.activationIDs(in: line)
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(activations.first?.network, .visa)
        XCTAssertEqual(activations.first?.id, "CARD_TEST_HASH_1234567890123=")
    }

    func testActivationJsonExtraction() {
        let line = #"nfcd: requestedApplet: {"aid": "A0000000041010", "passId": "CARD_TEST_HASH_1234567890123="}"#
        let activations = WalletScanParser.activationIDs(in: line)
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(activations.first?.network, .mastercard)
        XCTAssertEqual(activations.first?.id, "CARD_TEST_HASH_1234567890123=")
    }

    func testFallbackCardIDsDenylist() {
        let line = "Cached asset FrontFace.png and Preview and PlaceHolder with token VALID_FALLBACK_TOKEN_123456="
        let fallbacks = WalletScanParser.fallbackCardIDs(in: line)
        XCTAssertFalse(fallbacks.contains("FrontFace"))
        XCTAssertFalse(fallbacks.contains("Preview"))
        XCTAssertFalse(fallbacks.contains("PlaceHolder"))
        XCTAssertTrue(fallbacks.contains("VALID_FALLBACK_TOKEN_123456="))
    }

    func testCardItemDisplayTitle() {
        var card = CardItem(id: "CARD_TEST_HASH_1234567890123=", displayName: nil, paymentNetwork: "Visa")
        XCTAssertEqual(card.title, "Visa Card")

        card.displayName = "Monobank Black"
        XCTAssertEqual(card.title, "Monobank Black")

        let unknownCard = CardItem(id: "CARD_TEST_HASH_1234567890123=", displayName: nil, paymentNetwork: nil)
        XCTAssertEqual(unknownCard.title, "Payment Card")
    }

    func testTargetHostConfigurationFFI() {
        "10.7.0.1".withCString { cStr in
            let rc = al_set_target_host(cStr)
            XCTAssertEqual(rc, 0)
        }

        let candidates = ["10.7.0.1", "192.168.1.100"]
        let cStrings = candidates.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) }
        ptrs.withUnsafeBufferPointer { buf in
            let rc = al_set_target_hosts(buf.baseAddress, buf.count)
            XCTAssertEqual(rc, 0)
        }

        al_clear_target_hosts()
    }

    @MainActor
    func testAppViewModelTargetHostSync() {
        let vm = AppViewModel()
        vm.deviceIP = "10.7.0.1"
        vm.syncTargetHostsToRust()
        let candidates = NetworkStatus.tunnelHostCandidates()
        for cand in candidates {
            XCTAssertFalse(cand.hasPrefix("127."))
        }
    }
}

