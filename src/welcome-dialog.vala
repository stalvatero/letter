public class Mail.WelcomeDialog : Adw.Dialog {
    public WelcomeDialog () {
        Object (
            content_width: 520,
            content_height: 580,
            follows_content_size: false
        );

        if (Config.PROFILE == "development")
            add_css_class ("devel");

        var tour = new WelcomeTour ();
        tour.finished.connect (() => close ());

        var view = new Adw.ToolbarView () {
            content = tour.carousel,
        };
        view.add_top_bar (new Adw.HeaderBar ());
        view.add_bottom_bar (tour.footer);
        this.child = view;
        this.title = _("Welcome");

        map.connect (() => {
            Idle.add (() => {
                tour.reset_to_first_page ();
                return Source.REMOVE;
            });
        });
    }
}
