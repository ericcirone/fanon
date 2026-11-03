import XCTest
@testable import PixmaKit
@testable import ESCLKit

final class GeometryTests: XCTestCase {
    func testFullFlatbedAt300() throws {
        let g = try PageGeometry.make(ScanRequest(), model: .mx920)
        XCTAssertEqual(g.dpi, 300)
        XCTAssertEqual(g.width, 2552)      // 8.5 in
        XCTAssertEqual(g.height, 3508)     // A4 length (11.69 in)
        XCTAssertEqual(g.rawWidth, 2560)   // padded to 32
        XCTAssertEqual(g.xShift, 0)
    }

    func testOffsetIsAlignedTo32Pixels() throws {
        var r = ScanRequest()
        r.dpi = 150
        r.x = 300      // 1 in -> 150 px
        r.width = 600  // 2 in -> 300 px
        r.height = 300
        let g = try PageGeometry.make(r, model: .mx920)
        XCTAssertEqual(g.x, 128)
        XCTAssertEqual(g.xShift, 22)
        XCTAssertEqual(g.width, 300)
        XCTAssertEqual(g.rawWidth, 352)    // align32(300 + 22)
        XCTAssertEqual(g.height, 150)
    }

    func testADFIsCappedAt600DPIAndLegalLength() throws {
        var r = ScanRequest()
        r.source = .adf
        r.dpi = 1200
        r.height = 99_999
        let g = try PageGeometry.make(r, model: .mx920)
        XCTAssertEqual(g.dpi, 600)
        XCTAssertEqual(g.height, 8400)     // 14 in
    }

    func testRejectsNonNativeResolution() {
        var r = ScanRequest()
        r.dpi = 200
        XCTAssertThrowsError(try PageGeometry.make(r, model: .mx920))
    }

    func testIEEE1284Model() {
        let id = "MFG:Canon;CMD:MultiPass 2.1,IVEC;MDL:MX920 series;CLS:IMAGE;DES:Canon MX920 series;"
        XCTAssertEqual(IEEE1284.model(from: id), "Canon MX920 series")
    }
}

final class ESCLTests: XCTestCase {
    let appleStyleSettings = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
      <pwg:Version>2.6</pwg:Version>
      <scan:Intent>Photo</scan:Intent>
      <pwg:ScanRegions>
        <pwg:ScanRegion>
          <pwg:Height>1200</pwg:Height>
          <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
          <pwg:Width>900</pwg:Width>
          <pwg:XOffset>30</pwg:XOffset>
          <pwg:YOffset>60</pwg:YOffset>
        </pwg:ScanRegion>
      </pwg:ScanRegions>
      <pwg:InputSource>Feeder</pwg:InputSource>
      <scan:Duplex>true</scan:Duplex>
      <pwg:DocumentFormat>application/octet-stream</pwg:DocumentFormat>
      <scan:DocumentFormatExt>application/pdf</scan:DocumentFormatExt>
      <scan:ColorMode>Grayscale8</scan:ColorMode>
      <scan:XResolution>200</scan:XResolution>
      <scan:YResolution>200</scan:YResolution>
    </scan:ScanSettings>
    """

    func testParsesScanSettings() throws {
        let s = try XCTUnwrap(ESCL.parseSettings(Data(appleStyleSettings.utf8)))
        XCTAssertEqual(s.inputSource, "Feeder")
        XCTAssertTrue(s.duplex)
        XCTAssertEqual(s.format, .pdf)
        XCTAssertEqual(s.colorMode, "Grayscale8")
        XCTAssertEqual(s.x, 30)
        XCTAssertEqual(s.y, 60)
        XCTAssertEqual(s.width, 900)
        XCTAssertEqual(s.height, 1200)

        let r = s.scanRequest(model: .mx920)
        XCTAssertEqual(r.source, .adfDuplex)
        XCTAssertEqual(r.mode, .gray)
        XCTAssertEqual(r.dpi, 300)  // rounded up to a native resolution
    }

    func testCapabilitiesAreWellFormedXML() throws {
        let device = ESCL.Device(makeAndModel: "Canon MX920 series", serial: "F48139162F17",
                                 uuid: "6b1d7a2e-5ca9-4e0b-8a3f-f48139162f17", baseURL: "http://mac.local:8090")
        let xml = ESCL.capabilities(device, model: .mx920)
        XCTAssertTrue(XMLParser(data: Data(xml.utf8)).parse())
        XCTAssertTrue(xml.contains("<scan:MaxWidth>2552</scan:MaxWidth>"))
        XCTAssertTrue(XMLParser(data: Data(ESCL.status(state: "Idle", adfState: nil, jobs: []).utf8)).parse())
    }

    func testEncodesPDF() throws {
        let g = try PageGeometry.make({ var r = ScanRequest(); r.dpi = 75; r.width = 300; r.height = 300; return r }(), model: .mx920)
        let page = ScannedPage(geometry: g, pixels: Data(repeating: 0x80, count: g.bytesPerLine * g.height))
        let pdf = try ImageEncoder.encode([page, page], as: .pdf)
        XCTAssertEqual(pdf.prefix(5), Data("%PDF-".utf8))
        let jpeg = try ImageEncoder.encode([page], as: .jpeg)
        XCTAssertEqual(jpeg.prefix(2), Data([0xff, 0xd8]))
    }
}
