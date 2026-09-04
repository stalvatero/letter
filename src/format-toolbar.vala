public class Mail.FormatToolbar : Gtk.Box {
    public signal void insert_image ();

    private ComposeHtmlView view;
    private GenericArray<string> font_families = new GenericArray<string> ();

    public FormatToolbar (ComposeHtmlView view) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 6);
        this.view = view;
        hexpand = true;
        vexpand = false;
        valign = Gtk.Align.CENTER;
        add_css_class ("compose-toolbar");

        var font_drop = build_font_drop ();
        font_drop.add_css_class ("compose-font-drop");
        font_drop.tooltip_text = _("Font");
        font_drop.enable_search = true;
        font_drop.notify["selected"].connect (() => {
            var index = font_drop.selected;
            if (index < this.font_families.length)
                this.view.apply_font (this.font_families[index]);
        });

        var size_drop = new Gtk.DropDown.from_strings ({
            _("Small"),
            _("Normal"),
            _("Large"),
            _("Huge"),
        }) {
            selected = 1,
            valign = Gtk.Align.CENTER,
            vexpand = false,
            tooltip_text = _("Font size"),
        };
        size_drop.add_css_class ("compose-size-drop");
        size_drop.notify["selected"].connect (() => {
            string[] sizes = { "2", "3", "4", "6" };
            var index = size_drop.selected;
            if (index < sizes.length)
                this.view.apply_size (sizes[index]);
        });

        append (font_drop);
        append (size_drop);

        var formats = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4) {
            hexpand = true,
            vexpand = false,
            valign = Gtk.Align.CENTER,
        };
        formats.append (command_button ("format-text-bold-symbolic", _("Bold"), "Bold"));
        formats.append (command_button ("format-text-italic-symbolic", _("Italic"), "Italic"));
        formats.append (command_button ("format-text-underline-symbolic", _("Underline"), "Underline"));
        formats.append (command_button ("format-text-strikethrough-symbolic", _("Strikethrough"), "Strikethrough"));
        formats.append (color_menu_button ());
        formats.append (emoji_button ());
        formats.append (icon_button ("image-x-generic-symbolic", _("Insert Image"), () => insert_image ()));
        append (formats);
    }

    private Gtk.Button command_button (string icon, string tooltip, string command) {
        var button = icon_button (icon, tooltip, () => this.view.apply_command (command));
        return button;
    }

    private Gtk.Button icon_button (string icon, string tooltip, owned VoidFunc action) {
        var button = new Gtk.Button.from_icon_name (icon) {
            valign = Gtk.Align.CENTER,
            tooltip_text = tooltip,
            focus_on_click = false,
        };
        button.add_css_class ("flat");
        button.clicked.connect (() => action ());
        return button;
    }

    private Gtk.Widget emoji_button () {
        var chooser = new Gtk.EmojiChooser ();
        var button = new Gtk.MenuButton () {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Insert Emoji"),
            icon_name = "face-smile-symbolic",
            popover = chooser,
            always_show_arrow = false,
            direction = Gtk.ArrowType.DOWN,
            focus_on_click = false,
        };
        button.add_css_class ("flat");
        button.add_css_class ("compose-format-menu");
        chooser.emoji_picked.connect ((text) => this.view.insert_text (text));
        return button;
    }

    private Gtk.Widget color_menu_button () {
        var popover = new Gtk.Popover ();
        popover.add_css_class ("compose-color-popover");
        var button = new Gtk.MenuButton () {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Text Color"),
            popover = popover,
            always_show_arrow = false,
            direction = Gtk.ArrowType.DOWN,
            focus_on_click = false,
        };
        button.add_css_class ("flat");
        button.add_css_class ("compose-format-menu");
        button.icon_name = "color-select-symbolic";
        popover.child = build_color_palette (popover);
        return button;
    }

    private Gtk.Widget build_color_palette (Gtk.Popover popover) {
        var grid = new Gtk.Grid () {
            column_spacing = 6,
            row_spacing = 6,
            margin_start = 8,
            margin_end = 8,
            margin_top = 8,
            margin_bottom = 8,
        };
        var none = new Gtk.Button.from_icon_name ("edit-clear-symbolic") {
            tooltip_text = _("Default Color"),
            width_request = 28,
            height_request = 28,
            focus_on_click = false,
        };
        none.add_css_class ("flat");
        none.clicked.connect (() => {
            popover.popdown ();
            this.view.apply_color ("");
        });
        grid.attach (none, 0, 0, 1, 1);

        string[] colors = {
            "#1c1c1c", "#5e5c64", "#c01c28", "#e66100", "#e5a50a",
            "#26a269", "#1c71d8", "#813d9c", "#ffffff"
        };
        string[] names = {
            _("Black"), _("Gray"), _("Red"), _("Orange"), _("Gold"),
            _("Green"), _("Blue"), _("Purple"), _("White")
        };
        for (int i = 0; i < colors.length; i++) {
            var swatch = new Gtk.Button () {
                tooltip_text = names[i],
                width_request = 28,
                height_request = 28,
                focus_on_click = false,
            };
            swatch.add_css_class ("compose-color-swatch");
            swatch.add_css_class ("c-%s".printf (colors[i].substring (1).down ()));
            var hex = colors[i];
            swatch.clicked.connect (() => {
                popover.popdown ();
                this.view.apply_color (hex);
            });
            grid.attach (swatch, (i + 1) % 7, (i + 1) / 7, 1, 1);
        }
        return grid;
    }

    private Gtk.DropDown build_font_drop () {
        var labels = new Gtk.StringList (null);
        this.font_families = new GenericArray<string> ();
        labels.append (_("Sans Serif"));
        this.font_families.add ("sans-serif");
        labels.append (_("Serif"));
        this.font_families.add ("serif");
        labels.append (_("Monospace"));
        this.font_families.add ("monospace");
        return new Gtk.DropDown (labels, null) {
            selected = 0,
            valign = Gtk.Align.CENTER,
            vexpand = false,
        };
    }

    public delegate void VoidFunc ();
}
