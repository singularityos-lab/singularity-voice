namespace Singularity.Apps.Voice {

    public const int64 NS_PER_SECOND = 1000000000;

    public struct Span {
        public int64 start;
        public int64 end;

        public Span(int64 start, int64 end) {
            this.start = start;
            this.end = end;
        }

        public int64 length() {
            return end - start;
        }
    }

    public enum TrimMode {
        KEEP,
        REMOVE
    }

    public class TrimRange : Object {
        public const int64 MIN_LENGTH = NS_PER_SECOND / 10;

        public int64 duration { get; private set; }
        public int64 start { get; private set; }
        public int64 end { get; private set; }

        public signal void changed();

        public TrimRange(int64 duration) {
            this.duration = int64.max(duration, 0);
            start = 0;
            end = this.duration;
        }

        public int64 length {
            get { return end - start; }
        }

        public bool is_whole {
            get { return start <= 0 && end >= duration; }
        }

        public void move_start(int64 value) {
            int64 limit = int64.max(end - MIN_LENGTH, 0);
            int64 clamped = value.clamp(0, limit);
            if (clamped == start) return;
            start = clamped;
            changed();
        }

        public void move_end(int64 value) {
            int64 limit = int64.min(start + MIN_LENGTH, duration);
            int64 clamped = value.clamp(limit, duration);
            if (clamped == end) return;
            end = clamped;
            changed();
        }

        public void set_fraction(double from, double to) {
            double a = from.clamp(0, 1);
            double b = to.clamp(0, 1);
            if (b < a) {
                double t = a;
                a = b;
                b = t;
            }
            start = 0;
            end = duration;
            move_start((int64) (a * duration));
            move_end((int64) (b * duration));
            changed();
        }

        public void reset() {
            start = 0;
            end = duration;
            changed();
        }

        public Span[] kept(TrimMode mode) {
            Span[] spans = {};
            if (mode == TrimMode.KEEP) {
                if (end > start) spans += Span(start, end);
                return spans;
            }
            if (start > 0) spans += Span(0, start);
            if (end < duration) spans += Span(end, duration);
            return spans;
        }

        public int64 kept_duration(TrimMode mode) {
            int64 total = 0;
            foreach (var span in kept(mode)) total += span.length();
            return total;
        }

        public bool changes_anything(TrimMode mode) {
            if (mode == TrimMode.KEEP) return !is_whole;
            return length > 0 && kept(mode).length > 0 && !is_whole;
        }
    }

    namespace Samples {
        public int64 from_ns(int64 ns, int rate) {
            if (ns <= 0 || rate <= 0) return 0;
            return ns / NS_PER_SECOND * rate + (ns % NS_PER_SECOND) * rate / NS_PER_SECOND;
        }

        public int64 to_ns(int64 samples, int rate) {
            if (samples <= 0 || rate <= 0) return 0;
            return samples / rate * NS_PER_SECOND + (samples % rate) * NS_PER_SECOND / rate;
        }

        public Span[] spans_from_ns(Span[] spans, int rate) {
            Span[] result = {};
            foreach (var span in spans) {
                int64 a = from_ns(span.start, rate);
                int64 b = from_ns(span.end, rate);
                if (b > a) result += Span(a, b);
            }
            return result;
        }

        public Span[] keep_in_chunk(Span[] keep, int64 chunk_start, int64 count) {
            Span[] result = {};
            int64 chunk_end = chunk_start + count;
            foreach (var span in keep) {
                int64 a = int64.max(span.start, chunk_start);
                int64 b = int64.min(span.end, chunk_end);
                if (b > a) result += Span(a - chunk_start, b - chunk_start);
            }
            return result;
        }

        public bool past_all(Span[] keep, int64 position) {
            foreach (var span in keep) {
                if (span.end > position) return false;
            }
            return true;
        }
    }

    public class PeakBuilder : Object {
        public int samples_per_peak { get; construct; }
        private float current = 0;
        private int filled = 0;
        private float[] values = {};

        public PeakBuilder(int samples_per_peak) {
            Object(samples_per_peak: int.max(samples_per_peak, 1));
        }

        public void feed_s16(int16[] samples) {
            foreach (int16 sample in samples) {
                float value = (sample < 0 ? -(float) sample : (float) sample) / 32768f;
                if (value > current) current = value;
                filled++;
                if (filled >= samples_per_peak) {
                    values += loudness(current);
                    current = 0;
                    filled = 0;
                }
            }
        }

        public static float loudness(float amplitude) {
            if (amplitude <= 0.001f) return 0;
            return float.min((float) Math.sqrt(amplitude), 1);
        }

        public float[] finish() {
            if (filled > 0) {
                values += loudness(current);
                current = 0;
                filled = 0;
            }
            return values;
        }
    }

    namespace Peaks {
        public float[] bucket(float[] peaks, int buckets) {
            var result = new float[int.max(buckets, 0)];
            if (buckets <= 0 || peaks.length == 0) return result;
            for (int i = 0; i < buckets; i++) {
                int64 from = (int64) i * peaks.length / buckets;
                int64 to = (int64) (i + 1) * peaks.length / buckets;
                if (to <= from) to = from + 1;
                float top = 0;
                for (int64 j = from; j < to && j < peaks.length; j++) {
                    if (peaks[j] > top) top = peaks[j];
                }
                result[i] = top;
            }
            return result;
        }

        public float[] slice(float[] peaks, int per_second, Span[] spans_ns) {
            float[] result = {};
            foreach (var span in spans_ns) {
                int64 a = Samples.from_ns(span.start, per_second);
                int64 b = Samples.from_ns(span.end, per_second);
                for (int64 i = a; i < b && i < peaks.length; i++) result += peaks[i];
            }
            return result;
        }

        public float from_db(double db) {
            if (db.is_nan() || db <= -60) return 0;
            if (db >= 0) return 1;
            return (float) Math.sqrt(Math.pow(10, db / 20));
        }

        public string encode(float[] peaks) {
            var bytes = new uint8[peaks.length];
            for (int i = 0; i < peaks.length; i++) bytes[i] = (uint8) (peaks[i].clamp(0, 1) * 255 + 0.5f);
            return Base64.encode(bytes);
        }

        public float[] decode(string text) {
            uint8[] bytes = Base64.decode(text);
            var peaks = new float[bytes.length];
            for (int i = 0; i < bytes.length; i++) peaks[i] = bytes[i] / 255f;
            return peaks;
        }
    }

    namespace Timecode {
        public string format(int64 ns, bool tenths = false) {
            int64 total = int64.max(ns, 0);
            int64 seconds = total / NS_PER_SECOND;
            int64 hours = seconds / 3600;
            int64 minutes = (seconds / 60) % 60;
            int64 secs = seconds % 60;
            string text = hours > 0
                ? "%lld:%02lld:%02lld".printf(hours, minutes, secs)
                : "%lld:%02lld".printf(minutes, secs);
            if (tenths) text += ".%lld".printf((total / (NS_PER_SECOND / 10)) % 10);
            return text;
        }
    }

    namespace Titles {
        public string next(string[] existing, string base_name) {
            int highest = 0;
            string prefix = base_name + " ";
            foreach (string title in existing) {
                if (!title.has_prefix(prefix)) continue;
                int64 number;
                if (int64.try_parse(title.substring(prefix.length), out number) && number > highest) highest = (int) number;
            }
            return "%s %d".printf(base_name, highest + 1);
        }
    }

    namespace TranscriptText {
        public string clean(string output) {
            var text = new StringBuilder();
            foreach (string raw in output.split("\n")) {
                string line = raw.strip();
                if (line.has_prefix("[") && line.contains("-->")) {
                    int close = line.index_of("]");
                    line = close >= 0 ? line.substring(close + 1) : "";
                }
                line = drop(drop(line, '[', ']'), '(', ')').strip();
                while (line.contains("  ")) line = line.replace("  ", " ");
                if (line == "" || line == "-") continue;
                if (text.len > 0) text.append_c(' ');
                text.append(line);
            }
            return text.str.strip();
        }

        private string drop(string line, char open, char close) {
            var result = new StringBuilder();
            int i = 0;
            while (i < line.length) {
                if (line[i] == open) {
                    int end = line.index_of_char(close, i + 1);
                    if (end > i) {
                        i = end + 1;
                        continue;
                    }
                }
                result.append_c(line[i]);
                i++;
            }
            return result.str;
        }
    }

    namespace DateGroups {
        public string key(DateTime date, DateTime now) {
            var day = new DateTime.local(date.get_year(), date.get_month(), date.get_day_of_month(), 0, 0, 0);
            var today = new DateTime.local(now.get_year(), now.get_month(), now.get_day_of_month(), 0, 0, 0);
            int64 days = today.difference(day) / TimeSpan.DAY;
            if (days <= 0) return "today";
            if (days == 1) return "yesterday";
            if (days < 7) return "week";
            return "%04d-%02d".printf(date.get_year(), date.get_month());
        }
    }

    namespace Search {
        public bool matches(string query, string title, string transcript) {
            string needle = query.strip().casefold();
            if (needle == "") return true;
            string haystack = (title + "\n" + transcript).casefold();
            foreach (string word in needle.split(" ")) {
                if (word != "" && !haystack.contains(word)) return false;
            }
            return true;
        }
    }

    public const double[] SPEEDS = { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 };

    public string speed_label(double speed) {
        string text = "%g".printf(speed);
        return "%s×".printf(text);
    }
}
