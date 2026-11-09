// Small helpers for calling Win32 from Swift: wide strings, the constants and macros
// Swift doesn't import cleanly, and the flip between the core's y-up coordinates and
// Windows' y-down ones.
#if os(Windows)
import DeskBuddyCore
import WinSDK

/// A NUL-terminated UTF-16 copy of a string, for the W functions.
func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }

func withWide<T>(_ s: String, _ body: (UnsafePointer<WCHAR>) -> T) -> T {
    s.withCString(encodedAs: UTF16.self, body)
}

func string(fromWide p: UnsafePointer<WCHAR>) -> String { String(decodingCString: p, as: UTF16.self) }

// Spelled out, because some are unsigned values Swift imports as Int32 or not at all.
let wsPopup: DWORD = 0x8000_0000
let wsExLayered: DWORD = 0x0008_0000
let wsExTopmost: DWORD = 0x0000_0008
let wsExToolWindow: DWORD = 0x0000_0080
let wsExTransparent: DWORD = 0x0000_0020
let wsExNoActivate: DWORD = 0x0800_0000
let gwlExStyle: Int32 = -20
let gwlpUserData: Int32 = -21
let swShowNoActivate: Int32 = 4
let swpNoSize: UINT = 0x0001
let swpNoZOrder: UINT = 0x0004
let swpNoActivate: UINT = 0x0010
let ulwAlpha: DWORD = 0x0000_0002
let acSrcOver: BYTE = 0
let acSrcAlpha: BYTE = 1
let dibRGBColors: UINT = 0

let wmDestroy: UINT = 0x0002
let wmTimer: UINT = 0x0113
let wmMouseMove: UINT = 0x0200
let wmLButtonDown: UINT = 0x0201
let wmLButtonUp: UINT = 0x0202
let wmRButtonUp: UINT = 0x0205
let wmContextMenu: UINT = 0x007B
let wmMouseActivate: UINT = 0x0021
let wmCaptureChanged: UINT = 0x0215
let wmApp: UINT = 0x8000
let maNoActivate: LRESULT = 3
let mkLButton: WPARAM = 0x0001

let vkLButton: Int32 = 0x01
let vkRButton: Int32 = 0x02
let smCYScreen: Int32 = 1
let smSwapButton: Int32 = 23

let nimAdd: DWORD = 0, nimModify: DWORD = 1, nimDelete: DWORD = 2
let nifMessage: UINT = 0x1, nifIcon: UINT = 0x2, nifTip: UINT = 0x4
let mfString: UINT = 0
let mfGrayed: UINT = 0x0001
let mfChecked: UINT = 0x0008
let mfPopup: UINT = 0x0010
let mfSeparator: UINT = 0x0800
let tpmRightButton: UINT = 0x0002
let wmCommand: UINT = 0x0111

let errorAlreadyExists: DWORD = 183
let errorPipeConnected: DWORD = 535
let errorBrokenPipe: DWORD = 109
let pipeAccessDuplex: DWORD = 0x0000_0003
let pipeRejectRemoteClients: DWORD = 0x0000_0008
let pipeUnlimitedInstances: DWORD = 255

let invalidHandle = HANDLE(bitPattern: -1)

/// MAKEINTRESOURCEW, which Swift doesn't import.
func intResource(_ id: UInt16) -> UnsafePointer<WCHAR>? { UnsafePointer(bitPattern: UInt(id)) }

/// The main screen's height, which every flip turns on: Windows counts y down from
/// the main screen's top, the core counts it up from its bottom.
var mainScreenHeight: Double { Double(GetSystemMetrics(smCYScreen)) }

/// A Windows screen rectangle, in the core's coordinates.
func rect(_ r: RECT) -> Rect {
    Rect(x: Double(r.left), y: mainScreenHeight - Double(r.bottom), width: Double(r.right - r.left), height: Double(r.bottom - r.top))
}

/// The top left corner Windows wants for a frame in the core's coordinates.
func topLeft(_ frame: Rect) -> POINT {
    POINT(x: LONG(frame.minX.rounded()), y: LONG((mainScreenHeight - frame.maxY).rounded()))
}
#endif
