namespace Singularity.Apps.Voice {

    public class VoiceApp : Singularity.Application {
        public GLib.Settings settings { get; private set; }
        public Library library { get; private set; }
        public InputDevices devices { get; private set; }

        private VoiceWindow? window = null;
        private bool record_pending = false;

        public VoiceApp() {
            Object(application_id: "dev.sinty.voice", flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option("record", 0, OptionFlags.NONE, OptionArg.NONE, _("Start a new recording"), null);
        }

        protected override int handle_local_options(VariantDict options) {
            if (!options.contains("record")) return -1;
            try {
                register(null);
            } catch (Error e) {
                warning("Recorder: %s", e.message);
                return 1;
            }
            if (get_is_remote()) {
                activate_action("record", null);
                return 0;
            }
            record_pending = true;
            return -1;
        }

        protected override void startup() {
            base.startup();
            unowned string[]? gst_args = null;
            Gst.init(ref gst_args);
            var provider = new Gtk.CssProvider();
            provider.load_from_string(CSS);
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_USER + 1);
            settings = new GLib.Settings("dev.sinty.voice");
            library = new Library();
            devices = new InputDevices();

            var menu = new GLib.Menu();
            var file_menu = new GLib.Menu();
            var f1 = new GLib.Menu();
            f1.append(_("New Recording"), "app.record");
            file_menu.append_section(null, f1);
            var f2 = new GLib.Menu();
            f2.append(_("Export…"), "win.export");
            f2.append(_("Share…"), "win.share");
            f2.append(_("Show in Files"), "win.show-in-files");
            f2.append(_("Add Moment to a Note…"), "win.add-moment");
            file_menu.append_section(null, f2);
            var f3 = new GLib.Menu();
            f3.append(_("Close Window"), "win.close");
            f3.append(_("Quit"), "app.quit");
            file_menu.append_section(null, f3);
            menu.append_submenu(_("File"), file_menu);
            var edit_menu = new GLib.Menu();
            var e1 = new GLib.Menu();
            e1.append(_("Rename…"), "win.rename");
            e1.append(_("Trim…"), "win.trim");
            e1.append(_("Transcribe"), "win.transcribe");
            edit_menu.append_section(null, e1);
            var e2 = new GLib.Menu();
            e2.append(_("Delete"), "win.delete");
            edit_menu.append_section(null, e2);
            var e4 = new GLib.Menu();
            e4.append(_("Search Recordings"), "win.search");
            edit_menu.append_section(null, e4);
            var e3 = new GLib.Menu();
            e3.append(_("Settings"), "app.settings");
            edit_menu.append_section(null, e3);
            menu.append_submenu(_("Edit"), edit_menu);
            var play_menu = new GLib.Menu();
            play_menu.append(_("Play or Pause"), "win.play");
            var speeds = new GLib.Menu();
            foreach (double speed in SPEEDS) {
                var item = new GLib.MenuItem(speed_label(speed), null);
                item.set_action_and_target_value("win.speed", new Variant.double(speed));
                speeds.append_item(item);
            }
            play_menu.append_submenu(_("Speed"), speeds);
            menu.append_submenu(_("Playback"), play_menu);
            var rec_menu = new GLib.Menu();
            rec_menu.append(_("Pause or Resume"), "win.pause");
            rec_menu.append(_("Finish Recording"), "win.finish");
            rec_menu.append(_("Discard Recording"), "win.discard");
            menu.append_submenu(_("Recording"), rec_menu);
            set_menubar(menu);

            var quit_action = new SimpleAction("quit", null);
            quit_action.activate.connect(() => {
                if (window != null) window.close();
                quit();
            });
            add_action(quit_action);
            var record_action = new SimpleAction("record", null);
            record_action.activate.connect(() => {
                activate();
                window.start_recording();
            });
            add_action(record_action);
            var open_action = new SimpleAction("open", VariantType.STRING);
            open_action.activate.connect((param) => {
                activate();
                window.show_recording(library.find(param.get_string()));
            });
            add_action(open_action);
            var export_to = new SimpleAction("export-to", new VariantType("(sss)"));
            export_to.activate.connect((param) => {
                string id, format, path;
                param.get("(sss)", out id, out format, out path);
                activate();
                window.export_recording(library.find(id), ExportFormat.find(format), path);
            });
            add_action(export_to);
            var trim_to = new SimpleAction("trim-to", new VariantType("(sxxsb)"));
            trim_to.activate.connect((param) => {
                string id, mode;
                int64 start, end;
                bool copy;
                param.get("(sxxsb)", out id, out start, out end, out mode, out copy);
                activate();
                window.trim_recording(library.find(id), start, end, mode == "remove" ? TrimMode.REMOVE : TrimMode.KEEP, copy);
            });
            add_action(trim_to);
            var settings_action = new SimpleAction("settings", null);
            settings_action.activate.connect(() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync(BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings("dev.sinty.voice");
                } catch (Error e) {
                    warning("Recorder: cannot open settings: %s", e.message);
                }
            });
            add_action(settings_action);

            set_accels_for_action("app.record", {"<Control>r"});
            set_accels_for_action("app.settings", {"<Control>comma"});
            set_accels_for_action("app.quit", {"<Control>q"});
            set_accels_for_action("win.close", {"<Control>w"});
            set_accels_for_action("win.search", {"<Control>f"});
            set_accels_for_action("win.export", {"<Control><Shift>s"});
            set_accels_for_action("win.rename", {"F2"});
            set_accels_for_action("win.trim", {"<Control>t"});
            set_accels_for_action("win.delete", {"Delete"});
            set_accels_for_action("win.play", {"<Control>space"});
            set_accels_for_action("win.pause", {"<Control>p"});
            set_accels_for_action("win.finish", {"<Control>Return"});
        }

        protected override void shutdown() {
            if (devices != null) devices.stop();
            base.shutdown();
        }

        public override void open(File[] files, string hint) {
            activate();
            foreach (var f in files) {
                string uri = f.get_uri();
                if (!uri.has_prefix("sinty-recorder://")) continue;
                try {
                    var parsed = Uri.parse(uri, UriFlags.NONE);
                    var q = Uri.parse_params(parsed.get_query() ?? "", -1, "&", UriParamsFlags.NONE);
                    window.open_moment(q["id"] ?? "", int.parse(q["t"] ?? "0"));
                } catch (Error e) {
                    warning("Recorder: bad moment link %s", uri);
                }
            }
        }

        protected override void activate() {
            if (window == null) {
                window = new VoiceWindow(this);
                window.close_request.connect(() => {
                    if (window.busy_recording()) return true;
                    window = null;
                    return false;
                });
            }
            window.present();
            if (record_pending) {
                record_pending = false;
                window.start_recording();
            }
        }

        public static int main(string[] args) {
            Intl.setlocale(GLib.LocaleCategory.ALL, "");
            string locale_dir = "/usr/share/locale";
            try {
                string exe = GLib.FileUtils.read_link("/proc/self/exe");
                locale_dir = GLib.Path.build_filename(GLib.Path.get_dirname(GLib.Path.get_dirname(exe)), "share", "locale");
            } catch (GLib.Error e) { }
            Intl.bindtextdomain("singularity-voice", locale_dir);
            Intl.bind_textdomain_codeset("singularity-voice", "UTF-8");
            Intl.textdomain("singularity-voice");
            return new VoiceApp().run(args);
        }

        private const string CSS = """
.voice-time {
    font-size: 56px;
    font-weight: 300;
    font-feature-settings: "tnum";
}

.voice-time.paused {
    opacity: 0.5;
}

.voice-title {
    font-size: 24px;
    font-weight: 700;
}

.voice-clock {
    font-feature-settings: "tnum";
}

.voice-row-title {
    font-weight: 600;
}

.voice-play {
    min-width: 56px;
    min-height: 56px;
    border-radius: 999px;
    padding: 0;
}

.voice-record-dot {
    min-width: 12px;
    min-height: 12px;
    border-radius: 999px;
    background-color: #e01b24;
}

.voice-record-dot.paused {
    background-color: alpha(currentColor, 0.35);
}

.voice-stage {
    padding: 36px 40px 40px 40px;
}

.voice-transcript {
    padding: 4px 14px 12px 14px;
}
""";
    }
}
