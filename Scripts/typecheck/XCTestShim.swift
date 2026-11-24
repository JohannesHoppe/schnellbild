// Typecheck only (Scripts/typecheck.sh): the part of XCTest and XCUITest our
// tests use, as empty stand-ins. The Command Line Tools ship no XCTest; the
// tests themselves run on CI.
import Foundation
import CoreGraphics
import AppKit

open class XCTestRun { public var failureCount: Int { 0 } }
open class XCTestCase {
    public init() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
    open var continueAfterFailure = true
    public func addTeardownBlock(_ block: @escaping () -> Void) {}
    public func add(_ attachment: XCTAttachment) {}
    open var name: String { "" }
    open var testRun: XCTestRun? { nil }
}
/// SwiftPM's resource bundle of a test target.
extension Bundle { public static var module: Bundle { .main } }
open class XCTAttachment {
    public enum Lifetime { case keepAlways, deleteOnSuccess }
    public init(screenshot: XCUIScreenshot) {}
    open var name: String? = nil
    open var lifetime: Lifetime = .deleteOnSuccess
}
public struct XCTSkip: Error { public init(_ message: String = "") {} }

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) {}
public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T { fatalError() }

// XCUITest
public struct XCUIKeyboardKey: RawRepresentable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public static let `return`: Self = "r", escape: Self = "e", space: Self = " ", delete: Self = "d",
                      end: Self = "E", home: Self = "H", leftArrow: Self = "l", rightArrow: Self = "R",
                      upArrow: Self = "u", downArrow: Self = "D", F1: Self = "1", F2: Self = "2", F5: Self = "5", F6: Self = "6", tab: Self = "t"
}
public struct XCUIElementType: Equatable {
    public var rawValue: UInt = 0
    public static let any = XCUIElementType(), menuItem = XCUIElementType(), textField = XCUIElementType(), dialog = XCUIElementType(),
                      sheet = XCUIElementType(), window = XCUIElementType(), button = XCUIElementType(), staticText = XCUIElementType(), menu = XCUIElementType(),
                      helpTag = XCUIElementType()
}
public final class XCUIElementQuery {
    public subscript(_ id: String) -> XCUIElement { XCUIElement() }
    public var firstMatch: XCUIElement { XCUIElement() }
    public var count: Int { 0 }
    public var allElementsBoundByIndex: [XCUIElement] { [] }
    public func element(boundBy index: Int) -> XCUIElement { XCUIElement() }
    public func matching(identifier: String) -> XCUIElementQuery { self }
    public func matching(_ predicate: NSPredicate) -> XCUIElementQuery { self }
    public var menuBarItems: XCUIElementQuery { self }
    public var menuItems: XCUIElementQuery { self }
    public var buttons: XCUIElementQuery { self }
    public var textFields: XCUIElementQuery { self }
    public func descendants(matching type: XCUIElementType) -> XCUIElementQuery { self }
}
public struct XCUIGestureVelocity {
    public init(_ value: CGFloat) {}
    public static let slow = XCUIGestureVelocity(0), fast = XCUIGestureVelocity(0), `default` = XCUIGestureVelocity(0)
}
public final class XCUICoordinate {
    public func withOffset(_ offset: CGVector) -> XCUICoordinate { self }
    public func press(forDuration duration: TimeInterval, thenDragTo other: XCUICoordinate, withVelocity velocity: XCUIGestureVelocity,
                      thenHoldForDuration holdDuration: TimeInterval) {}
    public func scroll(byDeltaX deltaX: CGFloat, deltaY: CGFloat) {}
    public func doubleClick() {}
    public func hover() {}
    public func press(forDuration duration: TimeInterval, thenDragTo other: XCUICoordinate) {}
    public func click() {}
    public func rightClick() {}
}
public final class XCUIScreenshot { public var image: NSImage { NSImage() } }
public final class XCUIScreen {
    public static let main = XCUIScreen()
    public func screenshot() -> XCUIScreenshot { XCUIScreenshot() }
}
public protocol XCUIElementSnapshot {
    var identifier: String { get }
    var label: String { get }
    var value: Any? { get }
}
private struct ElementSnapshot: XCUIElementSnapshot {
    var identifier: String { "" }
    var label: String { "" }
    var value: Any? { nil }
}
public class XCUIElement {
    public typealias ElementType = XCUIElementType
    public func snapshot() throws -> XCUIElementSnapshot { ElementSnapshot() }
    public var elementType: XCUIElementType { .any }
    public static func perform(withKeyModifiers flags: KeyModifierFlags, block: () -> Void) { block() }
    public func scroll(byDeltaX deltaX: CGFloat, deltaY: CGFloat) {}
    public func press(forDuration duration: TimeInterval, thenDragTo element: XCUIElement) {}
    public struct KeyModifierFlags: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = KeyModifierFlags(rawValue: 1), control = KeyModifierFlags(rawValue: 2), shift = KeyModifierFlags(rawValue: 4), option = KeyModifierFlags(rawValue: 8)
    }
    public var exists: Bool { false }
    public var isHittable: Bool { false }
    public var isEnabled: Bool { false }
    public var frame: CGRect { .zero }
    public var label: String { "" }
    public var identifier: String { "" }
    public var title: String { "" }
    public var value: Any? { nil }
    public var firstMatch: XCUIElement { self }
    public var debugDescription: String { "" }
    public func click() {}
    public func screenshot() -> XCUIScreenshot { XCUIScreenshot() }
    public func doubleClick() {}
    public func hover() {}
    public func coordinate(withNormalizedOffset offset: CGVector) -> XCUICoordinate { XCUICoordinate() }
    public func adjust(toNormalizedSliderPosition position: CGFloat) {}
    public func rightClick() {}
    public func typeText(_ text: String) {}
    public func typeKey(_ key: XCUIKeyboardKey, modifierFlags: KeyModifierFlags) {}
    public func activate() {}
    public func typeKey(_ key: String, modifierFlags: KeyModifierFlags) {}
    public func waitForExistence(timeout: TimeInterval) -> Bool { false }
    public func descendants(matching type: XCUIElementType) -> XCUIElementQuery { XCUIElementQuery() }
    public var staticTexts: XCUIElementQuery { XCUIElementQuery() }
    public var buttons: XCUIElementQuery { XCUIElementQuery() }
    public var checkBoxes: XCUIElementQuery { XCUIElementQuery() }
    public var textFields: XCUIElementQuery { XCUIElementQuery() }
    public var searchFields: XCUIElementQuery { XCUIElementQuery() }
    public var secureTextFields: XCUIElementQuery { XCUIElementQuery() }
    public var menuItems: XCUIElementQuery { XCUIElementQuery() }
    public var menuBars: XCUIElementQuery { XCUIElementQuery() }
    public var menuBarItems: XCUIElementQuery { XCUIElementQuery() }
    public var windows: XCUIElementQuery { XCUIElementQuery() }
    public var toolbars: XCUIElementQuery { XCUIElementQuery() }
    public var radioButtons: XCUIElementQuery { XCUIElementQuery() }
    public var tabs: XCUIElementQuery { XCUIElementQuery() }
    public var images: XCUIElementQuery { XCUIElementQuery() }
    public var textViews: XCUIElementQuery { XCUIElementQuery() }
    public var scrollViews: XCUIElementQuery { XCUIElementQuery() }
    public var sheets: XCUIElementQuery { XCUIElementQuery() }
    public var dialogs: XCUIElementQuery { XCUIElementQuery() }
    public var outlines: XCUIElementQuery { XCUIElementQuery() }
    public var cells: XCUIElementQuery { XCUIElementQuery() }
}
public final class XCUIApplication: XCUIElement {
    public override init() {}
    public init(url: URL) {}
    public init(bundleIdentifier: String) {}
    public var launchArguments: [String] = []
    public func launch() {}
    public func terminate() {}
    public enum State { case unknown, notRunning, runningBackground, runningForeground }
    public var state: State { .unknown }
}
