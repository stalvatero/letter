/* Shown instead of the main shell when GNOME Online Accounts has no mail.
 * Includes the same three-page welcome tour so first launch is not a dead end. */
public class Mail.SetupWindow : Adw.ApplicationWindow {
    public signal void tour_finished ();

    public SetupWindow (Gtk.Application app) {
        Object (
            application: app,
            title: Utils.app_display_name (),
            default_width: 560,
            default_height: 580,
            resizable: false
        );

        if (Config.PROFILE == "development")
            add_css_class ("devel");

        var tour = new WelcomeTour ();
        tour.finished.connect (() => tour_finished ());

        var view = new Adw.ToolbarView () {
            content = tour.carousel,
        };
        view.add_top_bar (new Adw.HeaderBar ());
        view.add_bottom_bar (tour.footer);
        this.content = view;

        map.connect (() => {
            Idle.add (() => {
                tour.reset_to_first_page ();
                return Source.REMOVE;
            });
        });
    }
}
