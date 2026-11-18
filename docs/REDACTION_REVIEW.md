# Review screenshot redactions

Import a screenshot and wait for the review pane. Select any finding to locate it on the image and
choose **Include** or **Exclude**. Option-Up Arrow and Option-Down Arrow move between findings. Likely findings start included. The detector's remaining
findings start pending, including uncertain or ambiguous findings. Review also flags geometry
that covers a whole word or line because a more precise boundary could not be measured.

Choose **Draw** and drag on the screenshot to add a rectangle. **Add Rectangle** places a
rectangle in the center without a pointer gesture. In **Select** mode, drag a manual rectangle
to move it or drag a corner handle to resize it. The selection also has labeled position and
size steppers and a delete button, accessible by keyboard or VoiceOver using macOS keyboard
navigation. Command-Z undoes the last edit. Shift-Command-Z redoes it. One completed drag is one
edit. History is limited to 100 edits and clears on close, replacement, or recognition restart.

Zoom in or out using the toolbar. Choose **Pan** to drag a zoomed image and **Fit** to restore the
initial view. Drawing, hit testing, and overlays share the same mapping between screen points and
the original image pixels. Display backing scale does not change a rectangle's pixel coordinates.

**Preview Redacted Image** is available after processing and after explicitly including or
excluding every pending candidate. It renders the reviewed document into a new flattened raster
in memory. An edit or new import invalidates the preview. **Back to Review** returns to the
editable source. RED-7 covers saving and copying the flattened output.

The candidate list shows classification metadata and geometry warnings. It never displays the
recognized value. The image is displayed by the app, without external previews or source-sharing
controls.
