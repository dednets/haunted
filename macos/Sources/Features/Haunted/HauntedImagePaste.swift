import AppKit

/// Ctrl+V image paste into a remote session.
///
/// In a native terminal an app like Claude Code answers Ctrl+V by reading the
/// LOCAL clipboard itself — the terminal never sees the image. In a Haunted
/// tab that app runs on the workstation, where the Mac's clipboard does not
/// exist, so the keystroke alone can never work: the image bytes have to
/// cross the wire. This shim restores native behavior for exactly that case —
/// a plain Ctrl+V, on a surface attached through a workstation target, with
/// an image on the pasteboard — by uploading the image (`haunted upload`,
/// MSG_UPLOAD_* underneath) and typing the returned remote path into the
/// session, which is the same text an image file dropped onto a terminal
/// produces and what such apps already accept.
///
/// Everything else passes through untouched: no image (or a local tab) keeps
/// sending the raw 0x16 so app-side clipboard reading still works where it
/// can, and Cmd+V text paste is not involved at all.
enum HauntedImagePaste {
    /// The keyDown hook (SurfaceView.keyDown, guarded by PASTE-01): true
    /// means the event was consumed and an upload is in flight.
    @MainActor
    static func intercept(event: NSEvent, surfaceView: Ghostty.SurfaceView) -> Bool {
        guard isImagePasteKey(event: event),
              let (identity, target) =
                HauntedManager.shared.uploadTarget(for: surfaceView),
              let png = pngData(from: .general)
        else { return false }
        Task {
            await uploadAndPaste(png: png, identity: identity, target: target,
                                 surfaceView: surfaceView)
        }
        return true
    }

    /// Whether a live keyDown is the image-paste chord. Split from the pure
    /// string check below so the one macOS subtlety lives in exactly one
    /// place: under Control, `charactersIgnoringModifiers` reports the control
    /// character (Ctrl+V → 0x16, never "v"), so reading it made the chord
    /// never match and every paste fell through to the terminal as a literal
    /// ^V. `characters(byApplyingModifiers: [])` recovers the base key ("v")
    /// the same way Ghostty derives its unshifted_codepoint — see the note in
    /// NSEvent+Extension.ghosttyKeyEvent.
    static func isImagePasteKey(event: NSEvent) -> Bool {
        isImagePasteKey(characters: event.characters(byApplyingModifiers: []),
                        modifiers: event.modifierFlags)
    }

    /// A plain Ctrl+V and nothing else: any other modifier combination has
    /// its own meaning (Cmd+V is text paste, ctrl+shift bindings belong to
    /// the user) and must keep it.
    static func isImagePasteKey(characters: String?,
                                modifiers: NSEvent.ModifierFlags) -> Bool {
        let device = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        return characters == "v" && device == .control
    }

    /// PNG bytes from the pasteboard: a native PNG flavor wins, else any
    /// TIFF (screenshots, image copies from apps) is transcoded. Nil means
    /// "no image here" and downgrades the keystroke to a passthrough.
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    /// The daemon's reply is remote-influenced bytes about to be TYPED into
    /// a terminal, so it gets a strict grammar or it gets dropped: absolute,
    /// portable filename characters only, no `..` component, bounded length.
    /// (A hostile daemon could otherwise paste escape sequences or a shell
    /// command straight into the user's prompt.)
    static func sanitizedRemotePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count <= 1024 else { return nil }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz"
                + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !trimmed.split(separator: "/").contains("..")
        else { return nil }
        return trimmed
    }

    /// Runs the upload off the main thread and types the resulting path,
    /// followed by a space, like Finder's drag-and-drop does. `send` is a
    /// test seam; production falls through to the surface itself.
    @MainActor
    static func uploadAndPaste(
        png: Data,
        identity: HauntedClientIdentity,
        target: String,
        surfaceView: Ghostty.SurfaceView?,
        runner: HauntedProcessRunning = HauntedProcessRunner.shared,
        send: (@MainActor (String) -> Void)? = nil
    ) async {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("haunted-paste-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try png.write(to: temp, options: [.atomic])
            let path = try await HauntedCLI.upload(
                identity: identity, target: target, name: "paste.png",
                filePath: temp.path, runner: runner)
            let text = path + " "
            if let send {
                send(text)
            } else {
                surfaceView?.surfaceModel?.sendText(text)
            }
        } catch {
            /* The keystroke was consumed, so fail audibly rather than
             * silently pasting nothing. */
            NSSound.beep()
            NSLog("[haunted] image paste upload to %@ failed: %@",
                  target, "\(error)")
        }
    }
}
