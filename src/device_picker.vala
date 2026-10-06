using Gtk;

namespace Singularity.Apps.Voice {

    public class DevicePicker : Box {
        private VoiceApp app;
        private Box options;
        private Gee.HashMap<string, CheckButton> checks = new Gee.HashMap<string, CheckButton>();
        private bool syncing = false;

        public signal void chosen();

        public DevicePicker(VoiceApp app) {
            Object(orientation: Orientation.VERTICAL, spacing: 2);
            this.app = app;
            margin_top = 6;
            margin_bottom = 6;
            margin_start = 6;
            margin_end = 6;
            add_css_class("voice-device-picker");
            var heading = new Label(_("Record From"));
            heading.add_css_class("heading");
            heading.xalign = 0;
            heading.margin_start = 6;
            heading.margin_bottom = 4;
            append(heading);
            options = new Box(Orientation.VERTICAL, 2);
            append(options);
            app.devices.changed.connect(rebuild);
            app.settings.changed["input-device"].connect(sync_active);
            rebuild();
        }

        public static string current_label(VoiceApp app) {
            return app.devices.find(app.settings.get_string("input-device")).label;
        }

        private void rebuild() {
            Widget? child;
            while ((child = options.get_first_child()) != null) options.remove(child);
            checks.clear();
            CheckButton? group = null;
            foreach (var device in app.devices.all()) {
                var check = new CheckButton.with_label(device.label);
                check.add_css_class("voice-device-option");
                if (group != null) check.group = group;
                else group = check;
                string id = device.id;
                check.toggled.connect(() => {
                    if (syncing || !check.active) return;
                    if (app.settings.get_string("input-device") != id) app.settings.set_string("input-device", id);
                    chosen();
                });
                checks[id] = check;
                options.append(check);
            }
            sync_active();
        }

        private void sync_active() {
            string active = app.devices.find(app.settings.get_string("input-device")).id;
            syncing = true;
            foreach (var entry in checks.entries) entry.value.active = entry.key == active;
            syncing = false;
        }
    }
}
