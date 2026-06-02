import Testing
import Foundation
@testable import MailiaCore

@Test
func sanitizerRemovesScriptElements() throws {
    let result = try HTMLSanitizer().sanitize("<p>Hello</p><script>alert('x')</script>")

    #expect(result.content.contains("<p>Hello</p>"))
    #expect(!result.content.localizedCaseInsensitiveContains("<script"))
    #expect(!result.content.contains("alert('x')"))
}

@Test
func sanitizerRemovesInteractiveElementsAndEventHandlerAttributes() throws {
    let result = try HTMLSanitizer().sanitize("<button onclick=\"alert('x')\">Open</button>")

    #expect(result.content.contains("Open"))
    #expect(!result.content.localizedCaseInsensitiveContains("<button"))
    #expect(!result.content.localizedCaseInsensitiveContains("onclick"))
}

@Test
func sanitizerRemovesJavaScriptHref() throws {
    let result = try HTMLSanitizer().sanitize("<a href=\"javascript:alert('x')\">Open</a>")

    #expect(result.content.contains("<a>Open</a>"))
    #expect(!result.content.localizedCaseInsensitiveContains("javascript:"))
    #expect(!result.content.localizedCaseInsensitiveContains("href="))
}

@Test
func sanitizerKeepsAllowedLinkURLs() throws {
    let result = try HTMLSanitizer().sanitize("""
    <a href="mailto:support@example.com">Mail</a>
    <a href="#details">Jump</a>
    <a href="/settings">Settings</a>
    <a href="docs/setup.html">Docs</a>
    <a href="//example.com/protocol-relative">Blocked</a>
    """)

    #expect(result.content.contains("href=\"mailto:support@example.com\""))
    #expect(result.content.contains("href=\"#details\""))
    #expect(result.content.contains("href=\"/settings\""))
    #expect(result.content.contains("href=\"docs/setup.html\""))
    #expect(result.content.contains(">Blocked</a>"))
    #expect(!result.content.contains("href=\"//example.com/protocol-relative\""))
}

@Test
func sanitizerKeepsRemoteImageSourcesForDisplayPolicy() throws {
    let result = try HTMLSanitizer().sanitize("<img src=\"https://example.com/pixel.png\" width=\"320\" height=\"180\" srcset=\"https://example.com/pixel@2x.png 2x\">")

    #expect(!result.remoteContentBlocked)
    #expect(result.containsRemoteImages)
    #expect(result.content.contains("https://example.com/pixel.png"))
    #expect(result.content.contains("https://example.com/pixel@2x.png"))
    #expect(result.content.contains("width=\"320\""))
    #expect(result.content.contains("height=\"180\""))
    #expect(result.content.contains("data-mailia-remote-image=\"true\""))
    #expect(result.content.contains("data-mailia-has-explicit-size=\"true\""))
    #expect(result.content.contains("height: 180px"))
    #expect(result.content.contains("width: 320px"))
}

@Test
func sanitizerUpgradesHTTPImagesToHTTPS() throws {
    let result = try HTMLSanitizer().sanitize("""
    <img src="http://cdn.mcauto-images-production.sendgrid.net/fedb93c4bdeb888c/6b0badf1-2e15-4f63-ae41-fbbc26a4a393/240x240.png" srcset="http://cdn.mcauto-images-production.sendgrid.net/fedb93c4bdeb888c/6b0badf1-2e15-4f63-ae41-fbbc26a4a393/240x240.png 1x">
    <img src="http://example.com/not-upgraded.png">
    """)

    #expect(result.content.contains("https://cdn.mcauto-images-production.sendgrid.net/fedb93c4bdeb888c/6b0badf1-2e15-4f63-ae41-fbbc26a4a393/240x240.png"))
    #expect(result.content.contains("srcset=\"https://cdn.mcauto-images-production.sendgrid.net/fedb93c4bdeb888c/6b0badf1-2e15-4f63-ae41-fbbc26a4a393/240x240.png 1x\""))
    #expect(result.content.contains("https://example.com/not-upgraded.png"))
    #expect(!result.content.contains("http://"))
}

@Test
func sanitizerPreservesImageAttributeDimensionsAsInlineStyle() throws {
    let result = try HTMLSanitizer().sanitize("""
    <div style="display:flex; white-space:pre-wrap">
      <img height="20" width="20" style="border-radius:50%; margin-right:4px" src="https://avatars.githubusercontent.com/u/79189721?s=20&amp;v=4">
      <strong>wxtsky</strong> left a comment
    </div>
    """)

    #expect(result.content.contains("height=\"20\""))
    #expect(result.content.contains("width=\"20\""))
    #expect(result.content.contains("height: 20px"))
    #expect(result.content.contains("width: 20px"))
    #expect(result.content.contains("border-radius:50%") || result.content.contains("border-radius: 50%"))
    #expect(result.content.contains("margin-right:4px") || result.content.contains("margin-right: 4px"))
}

@Test
func sanitizerRemovesUnsafeImageURLs() throws {
    let result = try HTMLSanitizer().sanitize("<img src=\"javascript:alert('x')\" srcset=\"javascript:alert('x') 2x\">")

    #expect(!result.content.localizedCaseInsensitiveContains("javascript:"))
    #expect(!result.content.localizedCaseInsensitiveContains("src="))
    #expect(!result.content.localizedCaseInsensitiveContains("srcset="))
}

@Test
func displayPipelinePreservesAuthorColorsOnLightEmailSurface() throws {
    let exportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailiaDisplayPipelineTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: exportDirectory) }

    let html = """
    <div style="padding:10px">
      <div style="background:#ffffff !important; color:#333; width:510px">
        <h1 style="color:#333; font-size:40px">Updated Permissions Request</h1>
        <p style="color:#333">The GitHub App Claude is requesting additional access.</p>
      </div>
    </div>
    """

    let document = try EmailHTMLDisplayPipeline().document(
        exportedHTML: html,
        exportedText: "Updated Permissions Request",
        exportDirectory: exportDirectory
    )

    let output = try #require(document.html)
    #expect(document.sanitizerVersion == EmailHTMLDisplayPipeline.sanitizerVersion)
    #expect(output.contains("background:#ffffff"))
    #expect(output.contains("color:#333"))
    #expect(output.contains("font-size:40px"))
    #expect(document.textFallback == "Updated Permissions Request The GitHub App Claude is requesting additional access.")
}

@Test
func displayPipelineDerivesPreviewFromCanonicalHTMLInsteadOfExportedText() throws {
    let exportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailiaDisplayPipelineTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: exportDirectory) }

    let document = try EmailHTMLDisplayPipeline().document(
        exportedHTML: """
        <main>
          <p>HTML body wins</p>
          <p style="display:none">Hidden tracker text</p>
        </main>
        """,
        exportedText: "Plain text must not become preview",
        exportDirectory: exportDirectory
    )

    #expect(document.html?.contains("HTML body wins") == true)
    #expect(document.textFallback == "HTML body wins")
}

@Test
func displayPipelineBuildsCanonicalHTMLForTextOnlyExport() throws {
    let exportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailiaDisplayPipelineTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: exportDirectory) }

    let document = try EmailHTMLDisplayPipeline().document(
        exportedHTML: nil,
        exportedText: """
        Hello <Ryan>
        <#part type="image/png" filename="receipt.png"><#/part>
        Thanks & bye
        """,
        exportDirectory: exportDirectory
    )

    let output = try #require(document.html)
    #expect(output.hasPrefix("<pre>"))
    #expect(output.contains("Hello &lt;Ryan&gt;"))
    #expect(output.contains("Thanks &amp; bye"))
    #expect(!output.contains("<#part"))
    #expect(document.textFallback == "Hello <Ryan> Thanks & bye")
    #expect(document.hasAttachments)
}

@Test
func textExtractorIgnoresHiddenAndUnsafeEmailContent() {
    let text = HTMLTextExtractor().previewText(from: """
    <h1>Visible heading</h1>
    <script>secret()</script>
    <style>.x { color: red }</style>
    <p aria-hidden="true">Hidden aria</p>
    <p style="visibility:hidden">Hidden style</p>
    <p>Visible paragraph<br>Next line</p>
    """)

    #expect(text == "Visible heading Visible paragraph Next line")
}

@Test
func sanitizerInlinesLocalExportedRasterImagesOnlyInsideBaseDirectory() throws {
    let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailiaSanitizerTest-\(UUID().uuidString)", isDirectory: true)
    let nestedDirectory = baseDirectory.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let relativeImage = baseDirectory.appendingPathComponent("relative.png")
    let fileURLImage = nestedDirectory.appendingPathComponent("absolute.jpg")
    let svgImage = baseDirectory.appendingPathComponent("beacon.svg")
    let outsideImage = FileManager.default.temporaryDirectory.appendingPathComponent("outside.png")
    defer { try? FileManager.default.removeItem(at: outsideImage) }

    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: relativeImage)
    try Data([0xFF, 0xD8, 0xFF]).write(to: fileURLImage)
    try Data("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <path d="M10 10h80v80h-80z" fill="#6d84b4"/>
    </svg>
    """.utf8).write(to: svgImage)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: outsideImage)

    let html = """
    <img src="relative.png" srcset="relative@2x.png 2x">
    <img src="\(fileURLImage.absoluteString)">
    <img src="beacon.svg">
    <img src="../\(outsideImage.lastPathComponent)">
    """

    let inlined = try HTMLSanitizer().inlineLocalImageSources(in: html, baseDirectory: baseDirectory)
    let sanitized = try HTMLSanitizer().sanitize(inlined)

    #expect(sanitized.content.contains("data:image/png;base64,"))
    #expect(sanitized.content.contains("data:image/jpeg;base64,"))
    #expect(sanitized.content.contains("data:image/svg+xml;base64,"))
    #expect(!sanitized.content.contains("srcset="))
    #expect(!sanitized.content.contains(relativeImage.path))
    #expect(!sanitized.content.contains(fileURLImage.path))
    #expect(!sanitized.content.contains(outsideImage.path))
    #expect(!sanitized.content.contains("beacon.svg"))
}

@Test
func sanitizerRejectsUnsafeLocalSVGImages() throws {
    let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailiaSanitizerTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let unsafeSVG = baseDirectory.appendingPathComponent("unsafe.svg")
    try Data("""
    <svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)">
      <script>alert(1)</script>
      <image href="https://example.com/pixel.png"/>
    </svg>
    """.utf8).write(to: unsafeSVG)

    let html = #"<img src="unsafe.svg" alt="Unsafe SVG">"#
    let inlined = try HTMLSanitizer().inlineLocalImageSources(in: html, baseDirectory: baseDirectory)
    let sanitized = try HTMLSanitizer().sanitize(inlined)

    #expect(sanitized.content.contains("alt=\"Unsafe SVG\""))
    #expect(!sanitized.content.contains("data:image/svg+xml"))
    #expect(!sanitized.content.localizedCaseInsensitiveContains("onload"))
    #expect(!sanitized.content.localizedCaseInsensitiveContains("<script"))
    #expect(!sanitized.content.localizedCaseInsensitiveContains("https://example.com"))
    #expect(!sanitized.content.localizedCaseInsensitiveContains("src="))
}

@Test
func sanitizerRemovesLocalImagePathsThatCannotBeInlined() throws {
    let result = try HTMLSanitizer().sanitize("""
    <img src="/var/folders/example/MailiaExport-1/image.png" srcset="/var/folders/example/MailiaExport-1/image@2x.png 2x">
    <img src="file:///var/folders/example/MailiaExport-1/image.jpg">
    <img src="//example.com/pixel.png">
    """)

    #expect(!result.content.contains("/var/folders"))
    #expect(!result.content.localizedCaseInsensitiveContains("file:///"))
    #expect(!result.content.localizedCaseInsensitiveContains("srcset="))
    #expect(!result.content.localizedCaseInsensitiveContains("src=\"//"))
}

@Test
func sanitizerFiltersUnsafeStyleDeclarations() throws {
    let result = try HTMLSanitizer().sanitize("""
    <p style="color: red; position: absolute; background-image: url(javascript:alert(1)); width: expression(alert(1));">Hello</p>
    """)

    #expect(result.content.contains("color:red"))
    #expect(!result.content.localizedCaseInsensitiveContains("position"))
    #expect(!result.content.localizedCaseInsensitiveContains("background-image"))
    #expect(!result.content.localizedCaseInsensitiveContains("expression"))
    #expect(!result.content.localizedCaseInsensitiveContains("javascript"))
}

@Test
func sanitizerRemovesHiddenEmailSpacer() throws {
    let result = try HTMLSanitizer().sanitize("""
    <p>Visible message</p>
    <div style="display:none; white-space:nowrap; font:15px courier; line-height:0;">
      &nbsp; &nbsp; &nbsp;
    </div>
    """)

    #expect(result.content.contains("Visible message"))
    #expect(!result.content.localizedCaseInsensitiveContains("display:none"))
    #expect(!result.content.localizedCaseInsensitiveContains("white-space:nowrap"))
}

@Test
func displayNormalizerRemovesTrailingBlankSignature() throws {
    let html = """
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <div dir="auto">
      接受～ btw 工资卡需要是浦发的是吗 不能是其他行的
      <br />
      <br />
      <div title="hw_signature">
        <div title="hw_signature">
          <br />
        </div>
      </div>
    </div>
    """

    let result = HTMLDisplayNormalizer().normalize(html)

    #expect(result.contains("工资卡"))
    #expect(!result.localizedCaseInsensitiveContains("hw_signature"))
    #expect(!result.localizedCaseInsensitiveContains("<br"))
}

@Test
func displayVariantBuilderBlocksRemoteImagesWithPreservedBox() {
    let html = #"<p>Hello <a href="https://example.com"><img src="https://example.com/pixel.png" width="320" height="180"></a></p>"#

    let result = HTMLDisplayVariantBuilder().render(
        html,
        loadRemoteContent: false,
        hideQuotedReplyText: false
    )

    #expect(result.contains("Hello"))
    #expect(result.contains("mailia-remote-image-placeholder"))
    #expect(result.contains("aria-label=\"Remote image blocked\""))
    #expect(result.contains("width: 320px"))
    #expect(result.contains("height: 180px"))
    #expect(!result.localizedCaseInsensitiveContains("<img"))
    #expect(!result.contains("https://example.com/pixel.png"))
}

@Test
func displayVariantBuilderKeepsRemoteImagesWhenAllowed() {
    let html = #"<p>Hello <img src="https://example.com/pixel.png" width="320" height="180"></p>"#

    let result = HTMLDisplayVariantBuilder().render(
        html,
        loadRemoteContent: true,
        hideQuotedReplyText: false
    )

    #expect(result.contains("<img"))
    #expect(result.contains("https://example.com/pixel.png"))
    #expect(!result.contains("mailia-remote-image-placeholder"))
}

@Test
func displayVariantBuilderRemovesKnownQuotedReplyContainers() {
    let html = """
    <p>Current reply</p>
    <div class="gmail_quote">
      <p>Older message</p>
    </div>
    """

    let result = HTMLDisplayVariantBuilder().render(
        html,
        loadRemoteContent: true,
        hideQuotedReplyText: true
    )

    #expect(result.contains("Current reply"))
    #expect(!result.contains("Older message"))
    #expect(!result.contains("gmail_quote"))
}

@Test
func textNormalizerRemovesHimalayaAttachmentPartMarkers() {
    let text = """
    See attached invoice.
    <#part type=application/pdf filename="/Users/example/Downloads/invoice.pdf"><#/part>
    Thanks.
    """

    let result = MessageTextNormalizer().normalize(text)

    #expect(result.contains("See attached invoice."))
    #expect(result.contains("Thanks."))
    #expect(!result.contains("<#part"))
    #expect(!result.contains("invoice.pdf"))
}

@Test
func textNormalizerKeepsInlinePartLikeText() {
    let text = #"The literal text <#part type=application/pdf filename="/tmp/file.pdf"><#/part> was discussed."#

    let result = MessageTextNormalizer().normalize(text)

    #expect(result == text)
}

@Test
func textNormalizerRemovesTrailingQuotedReplyText() {
    let text = """
    I will handle this today.

    On May 30, Alice wrote:
    > Can you look at this?
    > Thanks.
    """

    let result = MessageTextNormalizer().removingTrailingQuotedReplyText(text)

    #expect(result == "I will handle this today.")
}
