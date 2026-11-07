import XCTest
@testable import Mirsa

final class DeviceRouteTests: XCTestCase {
    private let vpn = NetworkStatus.Interface(name: "utun4", ipv4: "10.7.0.2", netmask: "255.255.255.0")
    private let cellular = NetworkStatus.Interface(name: "pdp_ip0", ipv4: "100.64.1.2", netmask: "255.255.255.252")
    private let wifi = NetworkStatus.Interface(name: "en0", ipv4: "192.168.1.5", netmask: "255.255.255.0")

    func testCellularAndWifiUseActualVPNRoute() {
        for physical in [cellular, wifi] {
            XCTAssertTrue(NetworkStatus.routeAvailable(in: [physical, vpn], deviceIP: "10.7.0.1", selectedTunnelRoute: true))
            XCTAssertTrue(NetworkStatus.routeAvailable(in: [physical, vpn], deviceIP: "10.7.0.1", selectedTunnelRoute: nil))
        }
    }
    func testUnrelatedVPNDoesNotProveReachability() {
        XCTAssertFalse(NetworkStatus.routeAvailable(in: [vpn], deviceIP: "10.8.0.1", selectedTunnelRoute: nil))
        XCTAssertFalse(NetworkStatus.routeAvailable(in: [vpn], deviceIP: "10.7.0.1", selectedTunnelRoute: false))
    }
    func testConfiguredIPAloneDoesNotMeanConnected() {
        XCTAssertFalse(NetworkStatus.routeAvailable(in: [cellular], deviceIP: "10.7.0.1", selectedTunnelRoute: nil))
        XCTAssertFalse(NetworkStatus.routeAvailable(in: [], deviceIP: "10.7.0.1", selectedTunnelRoute: nil))
    }
    func testNoGuessWithoutNetmaskOrValidTarget() {
        let unknown = NetworkStatus.Interface(name: "utun4", ipv4: "10.7.0.2", netmask: nil)
        XCTAssertFalse(NetworkStatus.routeAvailable(in: [unknown], deviceIP: "10.7.0.1", selectedTunnelRoute: nil))
        XCTAssertFalse(NetworkStatus.routeAvailable(in: [vpn], deviceIP: "https://secret", selectedTunnelRoute: true))
    }
}
