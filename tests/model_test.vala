using Singularity.Apps.Voice;

private const int64 S = NS_PER_SECOND;

private void test_range_defaults() {
    var range = new TrimRange(10 * S);
    assert(range.start == 0);
    assert(range.end == 10 * S);
    assert(range.is_whole);
    assert(!range.changes_anything(TrimMode.KEEP));
    assert(!range.changes_anything(TrimMode.REMOVE));
}

private void test_range_clamping() {
    var range = new TrimRange(10 * S);
    range.move_start(-5 * S);
    assert(range.start == 0);
    range.move_end(20 * S);
    assert(range.end == 10 * S);
    range.move_end(4 * S);
    range.move_start(9 * S);
    assert(range.start == 4 * S - TrimRange.MIN_LENGTH);
    range.move_end(0);
    assert(range.end == range.start + TrimRange.MIN_LENGTH);
    assert(range.length == TrimRange.MIN_LENGTH);
}

private void test_range_fraction_swaps() {
    var range = new TrimRange(8 * S);
    range.set_fraction(0.75, 0.25);
    assert(range.start == 2 * S);
    assert(range.end == 6 * S);
    range.set_fraction(-1, 2);
    assert(range.is_whole);
}

private void test_kept_keep_mode() {
    var range = new TrimRange(10 * S);
    range.move_start(2 * S);
    range.move_end(7 * S);
    var spans = range.kept(TrimMode.KEEP);
    assert(spans.length == 1);
    assert(spans[0].start == 2 * S && spans[0].end == 7 * S);
    assert(range.kept_duration(TrimMode.KEEP) == 5 * S);
}

private void test_kept_remove_mode() {
    var range = new TrimRange(10 * S);
    range.move_start(2 * S);
    range.move_end(7 * S);
    var spans = range.kept(TrimMode.REMOVE);
    assert(spans.length == 2);
    assert(spans[0].start == 0 && spans[0].end == 2 * S);
    assert(spans[1].start == 7 * S && spans[1].end == 10 * S);
    assert(range.kept_duration(TrimMode.REMOVE) == 5 * S);
}

private void test_remove_at_edges() {
    var range = new TrimRange(10 * S);
    range.move_end(3 * S);
    var spans = range.kept(TrimMode.REMOVE);
    assert(spans.length == 1);
    assert(spans[0].start == 3 * S && spans[0].end == 10 * S);
    range.reset();
    range.move_start(6 * S);
    spans = range.kept(TrimMode.REMOVE);
    assert(spans.length == 1);
    assert(spans[0].start == 0 && spans[0].end == 6 * S);
}

private void test_sample_conversion() {
    assert(Samples.from_ns(S, 48000) == 48000);
    assert(Samples.from_ns(S / 2, 44100) == 22050);
    assert(Samples.from_ns(-3, 48000) == 0);
    assert(Samples.to_ns(48000, 48000) == S);
    assert(Samples.to_ns(24000, 48000) == S / 2);
    int64 hours = 5 * 3600 * S;
    assert(Samples.from_ns(hours, 48000) == (int64) 5 * 3600 * 48000);
    assert(Samples.to_ns(Samples.from_ns(hours, 48000), 48000) == hours);
}

private void test_chunk_keep() {
    Span[] keep = { Span(0, 100), Span(300, 400) };
    var parts = Samples.keep_in_chunk(keep, 50, 100);
    assert(parts.length == 1);
    assert(parts[0].start == 0 && parts[0].end == 50);
    parts = Samples.keep_in_chunk(keep, 90, 250);
    assert(parts.length == 2);
    assert(parts[0].start == 0 && parts[0].end == 10);
    assert(parts[1].start == 210 && parts[1].end == 250);
    parts = Samples.keep_in_chunk(keep, 120, 100);
    assert(parts.length == 0);
    assert(!Samples.past_all(keep, 399));
    assert(Samples.past_all(keep, 400));
}

private void test_peak_builder() {
    var builder = new PeakBuilder(4);
    int16[] a = { 0, 16384, -32768, 0, 100 };
    builder.feed_s16(a);
    int16[] b = { -8192, 0, 0 };
    builder.feed_s16(b);
    var peaks = builder.finish();
    assert(peaks.length == 2);
    assert(peaks[0] == 1.0f);
    assert(peaks[1] == 0.5f);
    assert(PeakBuilder.loudness(0) == 0);
    assert(PeakBuilder.loudness(0.0005f) == 0);
}

private void test_bucketing() {
    float[] peaks = { 0.1f, 0.9f, 0.2f, 0.3f, 0.5f, 0.4f };
    var two = Peaks.bucket(peaks, 2);
    assert(two.length == 2);
    assert(two[0] == 0.9f);
    assert(two[1] == 0.5f);
    var many = Peaks.bucket(peaks, 12);
    assert(many.length == 12);
    assert(many[2] == 0.9f && many[3] == 0.9f);
    assert(Peaks.bucket(new float[0], 5)[4] == 0);
}

private void test_peak_slice_and_encoding() {
    var peaks = new float[100];
    for (int i = 0; i < 100; i++) peaks[i] = i / 100f;
    Span[] spans = { Span(0, S), Span(4 * S, 5 * S) };
    var sliced = Peaks.slice(peaks, 20, spans);
    assert(sliced.length == 40);
    assert(sliced[20] == peaks[80]);
    var decoded = Peaks.decode(Peaks.encode(sliced));
    assert(decoded.length == 40);
    assert(Math.fabsf(decoded[39] - sliced[39]) < 0.003f);
    assert(Peaks.from_db(-60) == 0);
    assert(Peaks.from_db(0) == 1);
    assert(Math.fabsf(Peaks.from_db(-20) - 0.3162f) < 0.001f);
    assert(Math.fabsf(Peaks.from_db(-6.0206) - PeakBuilder.loudness(0.5f)) < 0.001f);
}

private void test_timecode() {
    assert(Timecode.format(0) == "0:00");
    assert(Timecode.format(65 * S) == "1:05");
    assert(Timecode.format(3723 * S) == "1:02:03");
    assert(Timecode.format(5 * S + S / 10 * 3, true) == "0:05.3");
}

private void test_titles() {
    string[] none = {};
    assert(Titles.next(none, "Recording") == "Recording 1");
    string[] some = { "Recording 1", "Meeting", "Recording 7", "Recording x" };
    assert(Titles.next(some, "Recording") == "Recording 8");
}

private void test_transcript_clean() {
    string raw = "[00:00:00.000 --> 00:00:02.000]   Hello  there.\n\n[00:00:02.000 --> 00:00:04.000]  See you (laughs) soon. [MUSIC]\n[BLANK_AUDIO]\n";
    assert(TranscriptText.clean(raw) == "Hello there. See you soon.");
    assert(TranscriptText.clean("") == "");
}

private void test_date_groups() {
    var now = new DateTime.local(2026, 9, 29, 10, 30, 0);
    assert(DateGroups.key(new DateTime.local(2026, 9, 29, 0, 5, 0), now) == "today");
    assert(DateGroups.key(new DateTime.local(2026, 9, 29, 23, 59, 0), now) == "today");
    assert(DateGroups.key(new DateTime.local(2026, 9, 28, 23, 59, 0), now) == "yesterday");
    assert(DateGroups.key(new DateTime.local(2026, 9, 23, 12, 0, 0), now) == "week");
    assert(DateGroups.key(new DateTime.local(2026, 9, 22, 12, 0, 0), now) == "2026-09");
    assert(DateGroups.key(new DateTime.local(2025, 12, 31, 12, 0, 0), now) == "2025-12");
    var new_year = new DateTime.local(2027, 1, 1, 9, 0, 0);
    assert(DateGroups.key(new DateTime.local(2026, 12, 31, 20, 0, 0), new_year) == "yesterday");
}

private void test_search() {
    assert(Search.matches("", "Anything", ""));
    assert(Search.matches("  ", "Anything", ""));
    assert(Search.matches("meet", "Team Meeting", ""));
    assert(Search.matches("MEETING team", "Team Meeting", ""));
    assert(Search.matches("budget", "Recording 3", "we talked about the budget"));
    assert(!Search.matches("budget lunch", "Recording 3", "we talked about the budget"));
    assert(!Search.matches("lecture", "Team Meeting", ""));
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/trim/defaults", test_range_defaults);
    Test.add_func("/trim/clamping", test_range_clamping);
    Test.add_func("/trim/fraction", test_range_fraction_swaps);
    Test.add_func("/trim/keep", test_kept_keep_mode);
    Test.add_func("/trim/remove", test_kept_remove_mode);
    Test.add_func("/trim/remove-edges", test_remove_at_edges);
    Test.add_func("/samples/conversion", test_sample_conversion);
    Test.add_func("/samples/chunk", test_chunk_keep);
    Test.add_func("/peaks/builder", test_peak_builder);
    Test.add_func("/peaks/bucket", test_bucketing);
    Test.add_func("/peaks/slice", test_peak_slice_and_encoding);
    Test.add_func("/timecode/format", test_timecode);
    Test.add_func("/titles/next", test_titles);
    Test.add_func("/transcript/clean", test_transcript_clean);
    Test.add_func("/library/date-groups", test_date_groups);
    Test.add_func("/library/search", test_search);
    return Test.run();
}
