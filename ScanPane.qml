import QtQuick
import QtMultimedia
import qs.Commons

// Webcam viewfinder for Sesame.
//
// While `active`, the default camera streams into the preview and a frame is
// written to `framePath` every `captureInterval` ms. The owner decodes each
// frame (zbarimg via bin/totp) and sets `busy` while it does, which pauses
// capture so frames never pile up. Loaded on demand so the camera is only
// opened while the scan view is showing.
Item {
  id: root

  property bool active: false
  property bool busy: false
  property bool mirror: true
  property string framePath: ""
  property int captureInterval: 450
  property color foreground: Color.foreground
  property color frameColor: Color.accent
  property color busyColor: Color.accent
  property string fontFamily: Style.font.family

  signal frameCaptured(string path)
  signal failed(string message)

  readonly property bool cameraReady: camera.active && !camera.error
  readonly property string statusText: {
    if (devices.videoInputs.length === 0) return "No camera found."
    if (camera.error) return camera.errorString || "Camera error."
    if (!camera.active) return "Starting camera…"
    return ""
  }

  MediaDevices { id: devices }

  CaptureSession {
    camera: Camera {
      id: camera
      active: root.active && devices.videoInputs.length > 0
      cameraDevice: devices.defaultVideoInput
      onErrorOccurred: function(error, message) { root.failed(message) }
    }
    videoOutput: output
    imageCapture: ImageCapture {
      id: capture
      onImageSaved: function(requestId, path) { root.frameCaptured(path) }
      onErrorOccurred: function(requestId, error, message) { root.failed(message) }
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Qt.rgba(0, 0, 0, 0.85)
    clip: true

    VideoOutput {
      id: output
      anchors.fill: parent
      fillMode: VideoOutput.PreserveAspectCrop
      transform: Scale {
        origin.x: output.width / 2
        xScale: root.mirror ? -1 : 1
      }
    }

    // Aiming frame: a QR held roughly inside this square decodes fastest.
    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width, parent.height) * 0.62
      height: width
      color: "transparent"
      radius: Style.space(8)
      border.width: Math.max(1, Style.space(2))
      border.color: root.busy ? root.busyColor : root.frameColor
      Behavior on border.color { ColorAnimation { duration: 150 } }
      opacity: root.cameraReady ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 180 } }
    }

    Text {
      anchors.centerIn: parent
      visible: root.statusText !== ""
      text: root.statusText
      color: "white"
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      width: parent.width - Style.space(24)
    }
  }

  Timer {
    interval: root.captureInterval
    repeat: true
    running: root.active && root.cameraReady && !root.busy && root.framePath !== ""
    onTriggered: if (capture.readyForCapture) capture.captureToFile(root.framePath)
  }
}
