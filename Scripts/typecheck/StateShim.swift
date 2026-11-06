// Typecheck only (Scripts/typecheck.sh): stands in for SwiftUI's @State,
// whose macro plugin ships with Xcode but not with the Command Line Tools.
import SwiftUI

@propertyWrapper
struct _State<Value>: DynamicProperty {
    init(wrappedValue: Value) {}
    init(initialValue: Value) {}
    var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    var projectedValue: Binding<Value> { fatalError() }
}
