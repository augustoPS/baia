// The tool's entry point, and nothing else.
//
// A `main.swift` rather than an `@main` type, matching the app target: with a
// `main.swift` in the target no type may use `@main`, and the flow lives in
// `Run.main()` where it can be read top to bottom without top-level code's rules
// about declaration order getting in the way.
Run.main()
