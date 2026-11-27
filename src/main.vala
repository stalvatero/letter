int main (string[] args) {
    /* Before GTK and WebKit open a GL display. On a hybrid laptop the
     * discrete GPU sorts first, and rendering there means every frame is
     * copied back to the GPU that actually drives the panel. */
    Mail.Utils.use_display_gpu ();
    /* The GPU compositor stays on. This only stops the detachable dmabuf
     * plane: WebKit drops that plane on every document change and the hole
     * flashes black. The page is painted into the texture GTK already holds. */
    Environment.set_variable ("WEBKIT_DISABLE_DMABUF_RENDERER", "1", true);
    Mail.Utils.sync_log_detail ("reader presents into the GTK texture; dmabuf plane off");

    Intl.setlocale (LocaleCategory.ALL, "");
    Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Config.LOCALEDIR);
    Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
    Intl.textdomain (Config.GETTEXT_PACKAGE);

    var app = new Mail.Application ();
    return app.run (args);
}
