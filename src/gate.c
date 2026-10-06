#include "gate.h"

struct _VoiceGate {
  GstPad *pad;
  gulong probe;
  gint paused;
  gint64 offset;
  GMutex lock;
};

static GstPadProbeReturn
gate_probe (GstPad *pad, GstPadProbeInfo *info, gpointer data)
{
  VoiceGate *gate = data;
  gint64 offset;

  if (g_atomic_int_get (&gate->paused))
    return GST_PAD_PROBE_DROP;
  g_mutex_lock (&gate->lock);
  offset = gate->offset;
  g_mutex_unlock (&gate->lock);
  if (offset > 0) {
    GstBuffer *buffer = gst_buffer_make_writable (GST_PAD_PROBE_INFO_BUFFER (info));
    if (GST_BUFFER_PTS_IS_VALID (buffer))
      GST_BUFFER_PTS (buffer) = GST_BUFFER_PTS (buffer) > (GstClockTime) offset ? GST_BUFFER_PTS (buffer) - offset : 0;
    if (GST_BUFFER_DTS_IS_VALID (buffer))
      GST_BUFFER_DTS (buffer) = GST_BUFFER_DTS (buffer) > (GstClockTime) offset ? GST_BUFFER_DTS (buffer) - offset : 0;
    GST_PAD_PROBE_INFO_DATA (info) = buffer;
  }
  return GST_PAD_PROBE_OK;
}

static void
gate_destroy (gpointer data)
{
  VoiceGate *gate = data;
  g_mutex_clear (&gate->lock);
  g_free (gate);
}

VoiceGate *
voice_gate_new (GstPad *pad)
{
  VoiceGate *gate = g_new0 (VoiceGate, 1);
  g_mutex_init (&gate->lock);
  gate->pad = gst_object_ref (pad);
  gate->probe = gst_pad_add_probe (pad, GST_PAD_PROBE_TYPE_BUFFER, gate_probe, gate, gate_destroy);
  return gate;
}

void
voice_gate_set_paused (VoiceGate *gate, gboolean paused)
{
  g_atomic_int_set (&gate->paused, paused ? 1 : 0);
}

void
voice_gate_add_offset (VoiceGate *gate, gint64 offset)
{
  g_mutex_lock (&gate->lock);
  gate->offset += offset;
  g_mutex_unlock (&gate->lock);
}

void
voice_gate_free (VoiceGate *gate)
{
  GstPad *pad;

  if (gate == NULL)
    return;
  pad = gate->pad;
  gst_pad_remove_probe (pad, gate->probe);
  gst_object_unref (pad);
}
