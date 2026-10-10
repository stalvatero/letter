class RequestLog : Object {
    public GenericArray<string> paths = new GenericArray<string> ();
    public string base_uri;
    private SocketService service = new SocketService ();

    public RequestLog () throws Error {
        SocketAddress bound;
        this.service.add_address (
            new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), 0),
            SocketType.STREAM,
            SocketProtocol.TCP,
            null,
            out bound
        );
        this.base_uri = "http://127.0.0.1:%u".printf (((InetSocketAddress) bound).port);
        this.service.incoming.connect ((connection) => {
            serve.begin (connection);
            return true;
        });
        this.service.start ();
    }

    private async void serve (SocketConnection connection) {
        try {
            var input = new DataInputStream (connection.input_stream);
            var request = yield input.read_line_async ();
            var parts = (request ?? "").split (" ");
            if (parts.length >= 2)
                this.paths.add (parts[1]);
            string? line;
            while ((line = yield input.read_line_async ()) != null && line.strip ().length > 0) {
            }
            var body = Base64.decode (PNG);
            var head = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                .printf (body.length);
            size_t written;
            yield connection.output_stream.write_all_async (head.data, Priority.DEFAULT, null, out written);
            yield connection.output_stream.write_all_async (body, Priority.DEFAULT, null, out written);
            yield connection.close_async ();
        } catch (Error e) {
        }
    }

    public bool saw (string path) {
        foreach (var seen in this.paths) {
            if (seen.has_prefix (path))
                return true;
        }
        return false;
    }

    public string dump () {
        return string.joinv (", ", this.paths.data);
    }
}

const int SKIP_WITHOUT_DISPLAY = 77;
const string PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

RequestLog requests;

string html_loading_remote_content_every_way (string base_uri) {
    return ("<!DOCTYPE html><html><body><link rel=\"stylesheet\" href=\"%s/link\">"
        + "<style>@import url(%s/import); @font-face { font-family: z; src: url(%s/font); } p { font-family: z; }</style>"
        + "<meta http-equiv=\"refresh\" content=\"0;url=%s/refresh\"><p>Hello</p>"
        + "<img src=\"%s/img\" width=\"10\" height=\"10\"><div style=\"background:url(%s/css-bg)\">x</div>"
        + "<table background=\"%s/table-bg\"><tr><td>t</td></tr></table><img srcset=\"%s/srcset 2x\">"
        + "<video poster=\"%s/poster\" src=\"%s/video\" preload=\"auto\"></video><audio src=\"%s/audio\" autoplay></audio>"
        + "<iframe src=\"%s/iframe\"></iframe><object data=\"%s/object\"></object><embed src=\"%s/embed\">"
        + "<img src=\"x\" onerror=\"fetch('%s/script')\"><svg onload=\"fetch('%s/svg-script')\"></svg>"
        + "</body></html>").printf (base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri, base_uri);
}

void spin (uint ms) {
    var loop = new MainLoop ();
    Timeout.add (ms, () => {
        loop.quit ();
        return false;
    });
    loop.run ();
}

void wait_for (string path) {
    for (int i = 0; i < 50 && !requests.saw (path); i++)
        spin (100);
}

string editor_html (Mail.ComposeHtmlView view) {
    var loop = new MainLoop ();
    string html = "";
    view.get_editor_html.begin ((obj, res) => {
        try {
            html = view.get_editor_html.end (res);
        } catch (Error e) {
            error ("editor script failed: %s", e.message);
        }
        loop.quit ();
    });
    loop.run ();
    return html;
}

Gtk.Window show (Gtk.Widget child) {
    var window = new Gtk.Window () { child = child, default_width = 400, default_height = 300 };
    window.present ();
    return window;
}

Mail.MessageContent hostile_message (string from_email, string path_prefix) {
    return new Mail.MessageContent () {
        uid = "test-" + from_email,
        subject = "Hello",
        from = "Sender <%s>".printf (from_email),
        from_email = from_email,
        html = html_loading_remote_content_every_way (requests.base_uri + path_prefix),
        has_remote_images = true,
    };
}

void assert_no_active_content (string path_prefix) {
    foreach (var path in new string[] {
        "/refresh", "/iframe", "/object", "/embed", "/script", "/svg-script",
    }) {
        if (requests.saw (path_prefix + path))
            error ("unexpected request %s (all: %s)", path, requests.dump ());
    }
}

void test_reader_blocks_untrusted_sender () {
    var reader = new Mail.MessageReader ();
    var window = show (reader);
    reader.show_content (hostile_message ("stranger@evil.example", "/untrusted"));
    spin (3000);
    if (requests.saw ("/untrusted/"))
        error ("untrusted message reached the network: %s", requests.dump ());
    window.destroy ();
}

void test_reader_blocks_untrusted_sender_without_remote_images () {
    var content = hostile_message ("stranger@evil.example", "/no-images");
    content.html = "<link rel=\"stylesheet\" href=\"%s/no-images/link\"><p>Hello</p>".printf (requests.base_uri);
    content.has_remote_images = false;
    var reader = new Mail.MessageReader ();
    var window = show (reader);
    reader.show_content (content);
    spin (2000);
    if (requests.saw ("/no-images/"))
        error ("untrusted message reached the network: %s", requests.dump ());
    window.destroy ();
}

void test_reader_loads_trusted_sender_without_active_content () {
    new Settings (Config.APP_ID).set_strv ("trusted-senders", { "friend@example.com" });
    var reader = new Mail.MessageReader ();
    var window = show (reader);
    reader.show_content (hostile_message ("friend@example.com", "/trusted"));
    foreach (var path in new string[] { "/trusted/img", "/trusted/css-bg", "/trusted/link" }) {
        wait_for (path);
        if (!requests.saw (path))
            error ("trusted message did not load %s (all: %s)", path, requests.dump ());
    }
    assert_no_active_content ("/trusted");
    window.destroy ();
    new Settings (Config.APP_ID).reset ("trusted-senders");
}

void test_compose_reply_loads_only_own_signature () {
    var signature = "<p>Me</p><img src=\"%s/signature/logo.png?v=1\">".printf (requests.base_uri);
    var policy = Mail.Utils.compose_content_policy_meta (
        new Settings (Config.APP_ID),
        hostile_message ("stranger@evil.example", "/compose"),
        null,
        null,
        signature
    );
    var view = new Mail.ComposeHtmlView (
        hostile_message ("stranger@evil.example", "/compose"),
        false,
        false,
        false,
        signature,
        null,
        policy
    );
    var window = show (view);
    wait_for ("/signature/logo.png");
    spin (1500);
    if (requests.saw ("/compose/"))
        error ("quoted message reached the network: %s", requests.dump ());
    assert (requests.saw ("/signature/logo.png"));

    var html = editor_html (view);
    assert (html.contains ("mail-quote"));
    assert (html.contains ("Hello"));
    window.destroy ();
}

int main (string[] args) {
    Test.init (ref args);
    if (!Gtk.init_check ()) {
        print ("No display, skipping\n");
        return SKIP_WITHOUT_DISPLAY;
    }
    Adw.init ();
    try {
        requests = new RequestLog ();
    } catch (Error e) {
        error ("Could not start the request log: %s", e.message);
    }
    Test.add_func ("/remote-content/reader-blocks-untrusted-sender", test_reader_blocks_untrusted_sender);
    Test.add_func (
        "/remote-content/reader-blocks-untrusted-sender-without-remote-images",
        test_reader_blocks_untrusted_sender_without_remote_images
    );
    Test.add_func (
        "/remote-content/reader-loads-trusted-sender-without-active-content",
        test_reader_loads_trusted_sender_without_active_content
    );
    Test.add_func ("/remote-content/compose-reply-loads-only-own-signature", test_compose_reply_loads_only_own_signature);
    return Test.run ();
}
