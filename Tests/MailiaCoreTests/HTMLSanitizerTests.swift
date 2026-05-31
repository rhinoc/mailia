import Testing
@testable import MailiaCore

@Test
func sanitizerRemovesScriptElements() throws {
    let result = try HTMLSanitizer().sanitize("<p>Hello</p><script>alert('x')</script>")

    #expect(result.content.contains("<p>Hello</p>"))
    #expect(!result.content.localizedCaseInsensitiveContains("<script"))
    #expect(!result.content.contains("alert('x')"))
}

@Test
func sanitizerRemovesEventHandlerAttributes() throws {
    let result = try HTMLSanitizer().sanitize("<button onclick=\"alert('x')\">Open</button>")

    #expect(result.content.contains("<button>Open</button>"))
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
func sanitizerKeepsRemoteImageSourcesForDisplayPolicy() throws {
    let result = try HTMLSanitizer().sanitize("<img src=\"https://example.com/pixel.png\" width=\"320\" height=\"180\" srcset=\"https://example.com/pixel@2x.png 2x\">")

    #expect(!result.remoteContentBlocked)
    #expect(result.content.contains("https://example.com/pixel.png"))
    #expect(result.content.contains("https://example.com/pixel@2x.png"))
    #expect(result.content.contains("width=\"320\""))
    #expect(result.content.contains("height=\"180\""))
}

@Test
func sanitizerBlocksRemoteImagesForDisplayWithSquarePlaceholders() throws {
    let html = """
    <a href="https://example.com/image-only"><img src="https://example.com/logo.png" width="144" height="40" alt="Start setup" style="border-radius: 8px; width: 144px;"></a>
    <a href="https://example.com/mixed">Read <img src="https://example.com/icon.png" width="16" height="16"></a>
    <img src="https://example.com/avatar.png" width="16" height="16" srcset="https://example.com/avatar@2x.png 2x">
    """

    let result = try HTMLSanitizer().blockRemoteImages(in: html)

    #expect(result.remoteContentBlocked)
    #expect(!result.content.contains("href=\"https://example.com/image-only\""))
    #expect(result.content.contains("href=\"https://example.com/mixed\""))
    #expect(!result.content.localizedCaseInsensitiveContains("<img"))
    #expect(!result.content.contains("https://example.com/logo.png"))
    #expect(!result.content.contains("https://example.com/icon.png"))
    #expect(!result.content.contains("https://example.com/avatar.png"))
    #expect(result.content.contains("mailia-remote-image-placeholder"))
    #expect(result.content.contains("aria-label=\"Remote image blocked\""))
    #expect(!result.content.contains(">Remote image blocked<"))
    #expect(!result.content.contains("Start setup"))
    #expect(result.content.contains("width: 144px"))
    #expect(result.content.contains("height: 40px"))
    #expect(!result.content.localizedCaseInsensitiveContains("border-radius"))
}

@Test
func sanitizerRemovesUnsafeImageURLs() throws {
    let result = try HTMLSanitizer().sanitize("<img src=\"javascript:alert('x')\" srcset=\"javascript:alert('x') 2x\">")

    #expect(!result.content.localizedCaseInsensitiveContains("javascript:"))
    #expect(!result.content.localizedCaseInsensitiveContains("src="))
    #expect(!result.content.localizedCaseInsensitiveContains("srcset="))
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
func textNormalizerRemovesHimalayaAttachmentPartMarkers() {
    let text = """
    See attached invoice.
    <#part type=application/pdf filename="/Users/ryan/Downloads/MC72260929.pdf"><#/part>
    Thanks.
    """

    let result = MessageTextNormalizer().normalize(text)

    #expect(result.contains("See attached invoice."))
    #expect(result.contains("Thanks."))
    #expect(!result.contains("<#part"))
    #expect(!result.contains("MC72260929.pdf"))
}

@Test
func textNormalizerKeepsInlinePartLikeText() {
    let text = #"The literal text <#part type=application/pdf filename="/tmp/file.pdf"><#/part> was discussed."#

    let result = MessageTextNormalizer().normalize(text)

    #expect(result == text)
}
