namespace Singularity.Apps.Voice {

    public class Recording : Object {
        public string id { get; construct; }
        public string file_name { get; set; }
        public string title { get; set; }
        public int64 created { get; set; }
        public int64 duration { get; set; }
        public float[] peaks;
        public string transcript { get; set; default = ""; }

        public signal void changed();

        public Recording(string id) {
            Object(id: id);
        }

        public File file(Library library) {
            return library.folder.get_child(file_name);
        }

        public string date_text() {
            var date = new DateTime.from_unix_local(created);
            var now = new DateTime.now_local();
            if (date.get_year() == now.get_year() && date.get_day_of_year() == now.get_day_of_year()) {
                return date.format(_("Today at %H:%M"));
            }
            if (date.get_year() == now.get_year()) return date.format(_("%-d %B at %H:%M")).strip();
            return date.format(_("%-d %B %Y")).strip();
        }

        public string short_date_text() {
            var date = new DateTime.from_unix_local(created);
            string group = DateGroups.key(date, new DateTime.now_local());
            if (group == "today" || group == "yesterday") return date.format(_("%H:%M"));
            if (group == "week") return date.format(_("%A at %H:%M"));
            return date.format(_("%-d %B at %H:%M")).strip();
        }
    }

    public class Library : Object {
        public File folder { get; private set; }
        public Gee.ArrayList<Recording> items { get; private set; default = new Gee.ArrayList<Recording>(); }

        public signal void added(Recording recording);
        public signal void removed(Recording recording);

        private File index;

        public Library(string? base_dir = null) {
            string root = base_dir ?? Path.build_filename(Environment.get_user_data_dir(), "dev.sinty.voice");
            folder = File.new_for_path(Path.build_filename(root, "recordings"));
            index = File.new_for_path(Path.build_filename(root, "recordings.json"));
            DirUtils.create_with_parents(folder.get_path(), 0700);
            load();
        }

        private void load() {
            items.clear();
            try {
                uint8[] contents;
                index.load_contents(null, out contents, null);
                var parser = new Json.Parser();
                parser.load_from_data((string) contents, contents.length);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return;
                foreach (var node in root.get_array().get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var obj = node.get_object();
                    if (!obj.has_member("id") || !obj.has_member("file")) continue;
                    var recording = new Recording(obj.get_string_member("id"));
                    recording.file_name = obj.get_string_member("file");
                    recording.title = obj.get_string_member_with_default("title", _("Recording"));
                    recording.created = obj.get_int_member_with_default("created", 0);
                    recording.duration = obj.get_int_member_with_default("duration", 0);
                    recording.peaks = Peaks.decode(obj.get_string_member_with_default("peaks", ""));
                    recording.transcript = obj.get_string_member_with_default("transcript", "");
                    if (!recording.file(this).query_exists()) continue;
                    items.add(recording);
                }
            } catch (Error e) {
                if (!(e is IOError.NOT_FOUND)) warning("Recorder: cannot read the recordings list: %s", e.message);
            }
            items.sort((a, b) => a.created > b.created ? -1 : (a.created < b.created ? 1 : 0));
        }

        public void save() {
            var builder = new Json.Builder();
            builder.begin_array();
            foreach (var recording in items) {
                builder.begin_object();
                builder.set_member_name("id").add_string_value(recording.id);
                builder.set_member_name("file").add_string_value(recording.file_name);
                builder.set_member_name("title").add_string_value(recording.title);
                builder.set_member_name("created").add_int_value(recording.created);
                builder.set_member_name("duration").add_int_value(recording.duration);
                builder.set_member_name("peaks").add_string_value(Peaks.encode(recording.peaks));
                if (recording.transcript != "") builder.set_member_name("transcript").add_string_value(recording.transcript);
                builder.end_object();
            }
            builder.end_array();
            var generator = new Json.Generator();
            generator.root = builder.get_root();
            try {
                FileUtils.set_contents(index.get_path(), generator.to_data(null));
            } catch (Error e) {
                warning("Recorder: cannot save the recordings list: %s", e.message);
            }
        }

        public string[] titles() {
            string[] list = {};
            foreach (var recording in items) list += recording.title;
            return list;
        }

        public string new_path(out string file_name) {
            string stamp = new DateTime.now_local().format("%Y-%m-%d %H-%M-%S");
            file_name = "%s.ogg".printf(stamp);
            int n = 2;
            while (folder.get_child(file_name).query_exists()) file_name = "%s %d.ogg".printf(stamp, n++);
            return folder.get_child(file_name).get_path();
        }

        public Recording add(string file_name, string title, int64 duration, float[] peaks) {
            var recording = new Recording(Uuid.string_random());
            recording.file_name = file_name;
            recording.title = title;
            recording.created = new DateTime.now_local().to_unix();
            recording.duration = duration;
            recording.peaks = peaks;
            items.insert(0, recording);
            save();
            added(recording);
            return recording;
        }

        public Recording? find(string id) {
            foreach (var recording in items) {
                if (recording.id == id) return recording;
            }
            return null;
        }

        public void rename(Recording recording, string title) {
            string clean = title.strip();
            if (clean == "" || clean == recording.title) return;
            recording.title = clean;
            save();
            recording.changed();
        }

        public void replace_audio(Recording recording, string new_path, int64 duration, float[] peaks) throws Error {
            var target = recording.file(this);
            File.new_for_path(new_path).move(target, FileCopyFlags.OVERWRITE);
            recording.duration = duration;
            recording.peaks = peaks;
            recording.transcript = "";
            save();
            recording.changed();
        }

        public void remove(Recording recording) {
            try {
                recording.file(this).trash(null);
            } catch (Error e) {
                try {
                    recording.file(this).delete();
                } catch (Error e2) {
                    warning("Recorder: cannot delete %s: %s", recording.file_name, e2.message);
                }
            }
            items.remove(recording);
            save();
            removed(recording);
        }
    }
}
