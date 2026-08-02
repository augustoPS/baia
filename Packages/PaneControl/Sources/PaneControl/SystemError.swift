import Darwin

/// Turns an errno value into the string `strerror` names it, for a caller that
/// wants to say what went wrong rather than the number it went wrong as.
public enum SystemError {
    public static func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
