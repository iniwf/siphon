/*
 * Copyright (C) 2007-2010 Samuel Vinson <samuelv0304@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */
//#if PJMEDIA_SOUND_IMPLEMENTATION==PJMEDIA_SOUND_IPHONE_SOUND
#if PJMEDIA_AUDIO_LEG_HAS_AUDIOQUEUE

#include <pjmedia/sound.h>
#include <pjmedia/errno.h>
#include <pj/assert.h>
#include <pj/pool.h>
#include <pj/log.h>
#include <pj/os.h>

#import <AudioToolbox/AudioToolbox.h>

static pj_bool_t audio_session_initialized = PJ_FALSE;

/* Latency settings */
static unsigned snd_input_latency = PJMEDIA_SND_DEFAULT_REC_LATENCY;
static unsigned snd_output_latency = PJMEDIA_SND_DEFAULT_PLAY_LATENCY;

#define THIS_FILE       "iphonesound.c"

#define KEEP_AUDIO_CATEGORY 0

#define BITS_PER_SAMPLE     16
#define BYTES_PER_SAMPLE    (BITS_PER_SAMPLE/8)
#define AUDIO_BUFFERS 3

#if 0
#   define TRACE_(x)    PJ_LOG(1,x)
#else
#   define TRACE_(x)
#endif

static pjmedia_snd_dev_info iphone_snd_dev_info =
{ "iPhone Sound Device", 1, 1, 8000 };
//{ "iPhone Sound Device", 1, 1, 16000 };

static pj_pool_factory *snd_pool_factory;

typedef struct AQStruct
{
  AudioQueueRef queue;
  AudioQueueBufferRef mBuffers[AUDIO_BUFFERS];
  AudioStreamBasicDescription mDataFormat;
  pj_uint32_t timestamp;

  pj_thread_desc thread_desc;
  pj_thread_t   *thread;

  void *buffer;
  pj_uint32_t bufferOffset;
} AQStruct;

struct pjmedia_snd_stream
{
  pj_pool_t *pool;

  pjmedia_dir dir;
  int rec_id;
  int play_id;
  unsigned clock_rate;
  unsigned channel_count;
  unsigned samples_per_frame;
  unsigned bits_per_sample;
  unsigned bytes_per_frame;

  pjmedia_snd_rec_cb rec_cb;
  pjmedia_snd_play_cb play_cb;

  void *user_data;

  AQStruct *play_strm; /**< Playback stream.       */
  AQStruct *rec_strm; /**< Capture stream.        */
};

#if 0
static pj_status_t pjmedia_snd_stream_pause(pjmedia_snd_stream *stream);
static pj_status_t pjmedia_snd_stream_resume(pjmedia_snd_stream *stream);
#endif

static void playAQBufferCallback(void *userData, AudioQueueRef outQ,
                                 AudioQueueBufferRef outQB)
{
  pjmedia_snd_stream *play_strm = userData;

  pj_status_t status = PJ_SUCCESS;

  if (!pj_thread_is_registered())
  {
    pj_bzero(play_strm->play_strm->thread_desc, sizeof(pj_thread_desc));
    pj_thread_register("iphone_playcb", play_strm->play_strm->thread_desc,
        &play_strm->play_strm->thread);
  }

  /* Calculate bytes per frame */
  outQB->mAudioDataByteSize = play_strm->bytes_per_frame;
  /* Get frame from application. */
  status = (*play_strm->play_cb)(play_strm->user_data,
        play_strm->play_strm->timestamp,
        (char *) outQB->mAudioData,
        outQB->mAudioDataByteSize);

  play_strm->play_strm->timestamp += play_strm->samples_per_frame;
  AudioQueueEnqueueBuffer(outQ, outQB, 0, NULL);

  if (status != PJ_SUCCESS)
  {
    PJ_LOG(1, (THIS_FILE, "playAQBufferCallback err %d\n", status));
  }
}

static void recAQBufferCallback(
                                void *userData,
                                AudioQueueRef inQ,
                                AudioQueueBufferRef inQB,
                                const AudioTimeStamp *inStartTime,
                                UInt32 inNumPackets,
                                const AudioStreamPacketDescription *inPacketDesc)
{
  pj_status_t status = PJ_SUCCESS;
  pjmedia_snd_stream *stream = userData;
  pj_uint8_t *buf;
  pj_uint32_t remaining, len;

  if (!pj_thread_is_registered())
  {
    pj_bzero(stream->rec_strm->thread_desc, sizeof(pj_thread_desc));
    pj_thread_register("iphone_reccb", stream->rec_strm->thread_desc,
              &stream->rec_strm->thread);
  }

  buf = inQB->mAudioData;
  remaining = inQB->mAudioDataByteSize;
  while (remaining > 0)
  {
    if (stream->rec_strm->bufferOffset >= stream->bytes_per_frame)
    {
      status = (*stream->rec_cb)(stream->user_data,
                                 stream->rec_strm->timestamp,
                                 stream->rec_strm->buffer,
                                 stream->bytes_per_frame);
      stream->rec_strm->timestamp += stream->samples_per_frame;
      stream->rec_strm->bufferOffset = 0;
    }

    len = stream->bytes_per_frame - stream->rec_strm->bufferOffset;
    if (len > remaining)
      len = remaining;
    pj_memcpy((char *)stream->rec_strm->buffer + stream->rec_strm->bufferOffset,
              buf, len);
    buf += len;
    remaining -= len;
    stream->rec_strm->bufferOffset += len;
  }

  AudioQueueEnqueueBuffer(inQ, inQB, 0, NULL);

  if (status != PJ_SUCCESS)
  {
    PJ_LOG(1, (THIS_FILE, "recAQBufferCallback err %d\n", status));
    return;
  }
}

static void audioSessionCategory(pjmedia_dir dir)
{
  UInt32 sessionCategory;
  OSStatus status;

  switch (dir)
  {
    case PJMEDIA_DIR_CAPTURE:
      TRACE_((THIS_FILE, "audioSessionCategory RecordAudio %d\n", dir));
      sessionCategory = kAudioSessionCategory_RecordAudio;
      break;
    case PJMEDIA_DIR_PLAYBACK:
      TRACE_((THIS_FILE, "audioSessionCategory MediaPlayback %d\n", dir));
      sessionCategory = kAudioSessionCategory_MediaPlayback;
      break;
    case PJMEDIA_DIR_CAPTURE_PLAYBACK:
      TRACE_((THIS_FILE, "audioSessionCategory PlayAndRecord %d\n", dir));
      sessionCategory = kAudioSessionCategory_PlayAndRecord;
      break;
    default:
      return;
  }

  // before instantiating the playback/recording audio queue object,
  // set the audio session category
  status = AudioSessionSetProperty(kAudioSessionProperty_AudioCategory,
                                   sizeof(sessionCategory), &sessionCategory);
  if (status)
    PJ_LOG(1, (THIS_FILE,
         "AudioSessionSetProperty Audio Category err %d\n", status));
}

/*
 * Technical Q&A QA1558
 * Audio Queue – Handling Playback Interruptions
 * Q: Do I need to recreate my Audio Queue after receiving an interruption if I
 * want to continue playback after the interruption?
 *
 * A: Yes. Currently to support Audio Queue playback though an interruption
 * event, applications need to dispose of the currently playing Audio Queue
 * object (by calling AudioQueueDispose) when the
 * AudioSessionInterruptionListener receives a kAudioSessionStartInterruption
 * notification.
 *
 * Once the interruption is over and the AudioSessionInterruptionListener
 * receives the kAudioSessionEndInterruption notification, a new Audio Queue
 * object will need to be created and started.
 *
 * Applications should save and restore any necessary state (eg. audio frame
 * number) required to pick up playback from the point of interruption.
 */
static
void interruptionListenerCallback(void *userData, UInt32 interruptionState)
{
  TRACE_((THIS_FILE, "interruptionListenerCallback %d.", interruptionState));
  if (interruptionState == kAudioSessionBeginInterruption)
  {
    TRACE_((THIS_FILE, "Interrupted. Stopping playback and/or recording ?"));
    //pjmedia_snd_stream_pause(stream); // When QA1558 will be fixed
    // FIXME pjsua_call_set_hold
    pjsua_set_null_snd_dev(); //  FIXME:
  }
  else if (interruptionState == kAudioSessionEndInterruption)
  {
    TRACE_((THIS_FILE,
               "Interruption was removed. Resume playback and/or recording ?"));
    //pjmedia_snd_stream_resume(stream); // When QA1558 will be fixed
    // FIXME pjsua_call_reinvite
    pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV,
                      PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV); // FIXME:
  }
}

// an audio queue object doesn't provide audio level information unless you
// enable it to do so
static void enableLevelMetering(AudioQueueRef queue)
{
  OSStatus status;
  UInt32 level = true;

  status = AudioQueueSetProperty(queue,
                                 kAudioQueueProperty_EnableLevelMetering,
                                 &level, sizeof(UInt32));
  if (status)
  {
    PJ_LOG(1, (THIS_FILE, "AudioQueueSetProperty err %d", status));
  }
}

PJ_DEF(pj_status_t) pjmedia_snd_init(pj_pool_factory *factory)
{
  TRACE_((THIS_FILE, "pjmedia_snd_init."));

  snd_pool_factory = factory;

  // TODO: Passer en param√®tre la structure pjmedia_snd_stream ???
  if (!audio_session_initialized)
  {
    TRACE_((THIS_FILE, "pjmedia_snd_init AudioSessionInitialize."));
    AudioSessionInitialize (NULL, kCFRunLoopDefaultMode,
                            interruptionListenerCallback, NULL);
    audio_session_initialized = PJ_TRUE;
  }
  return PJ_SUCCESS;
}

PJ_DEF(pj_status_t) pjmedia_snd_deinit(void)
{
  TRACE_((THIS_FILE, "pjmedia_snd_deinit."));

  snd_pool_factory = NULL;
  audio_session_initialized = PJ_FALSE;

  return PJ_SUCCESS;
}

PJ_DEF(int) pjmedia_snd_get_dev_count(void)
{
  TRACE_((THIS_FILE, "pjmedia_snd_get_dev_count."));
  /* Always return 1 */
  return 1;
}

PJ_DEF(const pjmedia_snd_dev_info*) pjmedia_snd_get_dev_info(unsigned index)
{
  TRACE_((THIS_FILE, "pjmedia_snd_get_dev_info %d.", index));
  /* Always return the default sound device */
  PJ_ASSERT_RETURN(index==0 || index==(unsigned)-1, NULL);
  return &iphone_snd_dev_info;
}

PJ_DEF(pj_status_t) pjmedia_snd_open_rec( int index,
                                          unsigned clock_rate,
                                          unsigned channel_count,
                                          unsigned samples_per_frame,
                                          unsigned bits_per_sample,
                                          pjmedia_snd_rec_cb rec_cb,
                                          void *user_data,
                                          pjmedia_snd_stream **p_snd_strm)
                                          {
  TRACE_((THIS_FILE, "pjmedia_snd_open_rec."));
  return pjmedia_snd_open(index, -2, clock_rate, channel_count,
                          samples_per_frame, bits_per_sample,
                          rec_cb, NULL, user_data, p_snd_strm);
                                          }

PJ_DEF(pj_status_t) pjmedia_snd_open_player( int index,
                                             unsigned clock_rate,
                                             unsigned channel_count,
                                             unsigned samples_per_frame,
                                             unsigned bits_per_sample,
                                             pjmedia_snd_play_cb play_cb,
                                             void *user_data,
                                             pjmedia_snd_stream **p_snd_strm )
                                             {
  TRACE_((THIS_FILE, "pjmedia_snd_open_player."));
  return pjmedia_snd_open(-2, index, clock_rate, channel_count,
                          samples_per_frame, bits_per_sample,
                          NULL, play_cb, user_data, p_snd_strm);
                                             }

PJ_DEF(pj_status_t) pjmedia_snd_open( int rec_id,
                                      int play_id,
                                      unsigned clock_rate,
                                      unsigned channel_count,
                                      unsigned samples_per_frame,
                                      unsigned bits_per_sample,
                                      pjmedia_snd_rec_cb rec_cb,
                                      pjmedia_snd_play_cb play_cb,
                                      void *user_data,
                                      pjmedia_snd_stream **p_snd_strm)
{
  pj_pool_t *pool;
  pjmedia_snd_stream *snd_strm;
  AQStruct *aq;
  OSStatus status;

  TRACE_((THIS_FILE, "pjmedia_snd_open."));
  /* Make sure sound subsystem has been initialized with
   * pjmedia_snd_init() */
  PJ_ASSERT_RETURN( snd_pool_factory != NULL, PJ_EINVALIDOP );

  /* Can only support 16bits per sample */
  PJ_ASSERT_RETURN(bits_per_sample == BITS_PER_SAMPLE, PJ_EINVAL);

  pool = pj_pool_create(snd_pool_factory, NULL, 128, 128, NULL);
  snd_strm = PJ_POOL_ZALLOC_T(pool, pjmedia_snd_stream);

  snd_strm->pool = pool;

  if (rec_id == -1) rec_id = 0;
  if (play_id == -1) play_id = 0;

  if (rec_id != -2 && play_id != -2)
  {
    snd_strm->dir = PJMEDIA_DIR_CAPTURE_PLAYBACK;
  }
  else if (rec_id != -2)
  {
    snd_strm->dir = PJMEDIA_DIR_CAPTURE;
  }
  else if (play_id != -2)
  {
    snd_strm->dir = PJMEDIA_DIR_PLAYBACK;
  }

#if KEEP_AUDIO_CATEGORY
  UInt32 size = sizeof(snd_strm->prevAudioSessionCategory);

  AudioSessionGetProperty(kAudioSessionProperty_AudioCategory, &size,
                          &snd_strm->prevAudioSessionCategory);
#endif

  audioSessionCategory(snd_strm->dir);

  // FIXME: est-ce n�cessaire ?
  status = AudioSessionSetActive(true);
  status = AudioSessionSetActive(false);
  if (status)
  {
    PJ_LOG(1, (THIS_FILE,
           "AudioSessionSetActive err %d\n", status));
    // return PJMEDIA_ERROR; // FIXME return ???
  }

  snd_strm->rec_id = rec_id;
  snd_strm->play_id = play_id;
  snd_strm->clock_rate = clock_rate;
  snd_strm->channel_count = channel_count;
  snd_strm->samples_per_frame = samples_per_frame;
  snd_strm->bits_per_sample = bits_per_sample;
  snd_strm->bytes_per_frame = samples_per_frame * bits_per_sample / 8;
  snd_strm->rec_cb = rec_cb;
  snd_strm->play_cb = play_cb;
  snd_strm->user_data = user_data;

  /* Create player stream */
  if (snd_strm->dir & PJMEDIA_DIR_PLAYBACK)
  {
    aq = snd_strm->play_strm = PJ_POOL_ZALLOC_T(pool, AQStruct);
    // Set up our audio format -- signed interleaved shorts (-32767 -> 32767), 16 bit stereo
    // The iphone does not want to play back float32s.
    aq->mDataFormat.mSampleRate = (Float64)clock_rate; // 8000 / 44100
    aq->mDataFormat.mFormatID = kAudioFormatLinearPCM;
    aq->mDataFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger |
    kAudioFormatFlagIsPacked;
    // this means each packet in the AQ has two samples, one for each
    // channel -> 4 bytes/frame/packet
    // In uncompressed audio, each packet contains exactly one frame.
    aq->mDataFormat.mFramesPerPacket = 1;
    aq->mDataFormat.mBytesPerFrame = aq->mDataFormat.mBytesPerPacket =
      channel_count * bits_per_sample / 8;
    aq->mDataFormat.mChannelsPerFrame = channel_count;

    aq->mDataFormat.mBitsPerChannel = 16; // FIXME
    TRACE_((THIS_FILE, "pjmedia_snd_open AudioQueueNewOutput."));
    status = AudioQueueNewOutput(&(aq->mDataFormat),
                                 playAQBufferCallback,
                                 snd_strm,
                                 CFRunLoopGetCurrent(),
                                 //	NULL,
                                 kCFRunLoopCommonModes,
                                 0,
                                 &(aq->queue));
    if (status)
    {
      PJ_LOG(1, (THIS_FILE, "AudioQueueNewOutput err %d", status));
      return PJMEDIA_ERROR; // FIXME
    }
    TRACE_((THIS_FILE, "pjmedia_snd_open AudioQueueSetParameter."));
    // set the volume of the playback audio queue
    AudioQueueSetParameter(aq->queue, kAudioQueueParam_Volume, 1.0);

    //FIXME: enable LevelMetering ??
    enableLevelMetering(aq->queue);
  }

  /* Create capture stream */
  if (snd_strm->dir & PJMEDIA_DIR_CAPTURE)
  {
    aq = snd_strm->rec_strm = PJ_POOL_ZALLOC_T(pool, AQStruct);
    // TODO allocate buffers ??
    aq->mDataFormat.mSampleRate = (Float64)clock_rate;
    aq->mDataFormat.mFormatID = kAudioFormatLinearPCM;
    aq->mDataFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger |
    kLinearPCMFormatFlagIsPacked;
    // In uncompressed audio, each packet contains exactly one frame.
    aq->mDataFormat.mFramesPerPacket = 1;
    aq->mDataFormat.mBytesPerPacket = aq->mDataFormat.mBytesPerFrame =
      channel_count * bits_per_sample / 8;
    aq->mDataFormat.mChannelsPerFrame = channel_count; // FIXME: always 1??
    aq->mDataFormat.mBitsPerChannel = 16; // FIXME

    aq->bufferOffset = 0;
    aq->buffer = pj_pool_zalloc(pool, snd_strm->bytes_per_frame);

    TRACE_((THIS_FILE, "pjmedia_snd_open AudioQueueNewInput."));
    status = AudioQueueNewInput (&(aq->mDataFormat),
                                 recAQBufferCallback,
                                 snd_strm,
                                 NULL,
                                 kCFRunLoopCommonModes,
                                 0,
                                 &(aq->queue));
    if (status)
    {
      PJ_LOG(1, (THIS_FILE, "AudioQueueNewInput err %d", status));
      return PJMEDIA_ERROR; // FIXME
    }

    // FIXME: enableLevelMetering ??
    enableLevelMetering(aq->queue);
  }

  *p_snd_strm = snd_strm;

  TRACE_((THIS_FILE, "pjmedia_snd_open finished."));
  return PJ_SUCCESS;
}

/**
 */
PJ_DEF(pj_status_t) pjmedia_snd_stream_start(pjmedia_snd_stream *stream)
{
  OSStatus status;
  pj_int32_t i;
  AQStruct *aq;

  TRACE_((THIS_FILE, "pjmedia_snd_stream_start."));

  // Activate the audio session immediately before process starts.
  status = AudioSessionSetActive(true);
  if (status)
  {
    PJ_LOG(1, (THIS_FILE,
           "AudioSessionSetActive err %d\n", status));
    // return PJMEDIA_ERROR; // FIXME return ???
  }

  if (stream->dir & PJMEDIA_DIR_PLAYBACK)
  {
    TRACE_((THIS_FILE, "pjmedia_snd_stream_start : play back starting..."));
    aq = stream->play_strm;
    UInt32 bufferBytes = stream->bytes_per_frame * aq->mDataFormat.mBytesPerFrame;
    for (i=0; i<AUDIO_BUFFERS; i++)
    {
      status = AudioQueueAllocateBuffer(aq->queue, bufferBytes,
                                        &(aq->mBuffers[i]));
      if (status)
      {
        PJ_LOG(1, (THIS_FILE,
            "AudioQueueAllocateBuffer[%d] err %d\n",i, status));
        // return PJMEDIA_ERROR; // FIXME return ???
      }
      /* "Prime" by calling the callback once per buffer */
      playAQBufferCallback (stream, aq->queue, aq->mBuffers[i]);
    }
    status = AudioQueueStart(aq->queue, NULL);
    if (status)
    {
      PJ_LOG(1, (THIS_FILE,
          "AudioQueueStart err %d\n", status));
    }
    TRACE_((THIS_FILE, "pjmedia_snd_stream_start : play back started"));
  }
  if (stream->dir & PJMEDIA_DIR_CAPTURE)
  {
    TRACE_((THIS_FILE, "pjmedia_snd_stream_start : capture starting..."));
    aq = stream->rec_strm;
    for (i = 0; i < AUDIO_BUFFERS; ++i)
    {
      status = AudioQueueAllocateBuffer (aq->queue, stream->bytes_per_frame,
                                         &(aq->mBuffers[i]));

      if (status)
      {
        PJ_LOG(1, (THIS_FILE,
            "AudioQueueAllocateBuffer[%d] err %d\n",i, status));
        // return PJMEDIA_ERROR; // FIXME return ???
      }
      AudioQueueEnqueueBuffer (aq->queue, aq->mBuffers[i], 0, NULL);
    }
    status = AudioQueueStart (aq->queue, NULL);
    if (status)
    {
      PJ_LOG(1, (THIS_FILE, "Starting capture stream error %d", status));
      return PJMEDIA_ENOSNDREC;
    }

    TRACE_((THIS_FILE, "pjmedia_snd_stream_start : capture started..."));
  }

  return PJ_SUCCESS;
}

/**
 */
PJ_DEF(pj_status_t) pjmedia_snd_stream_stop(pjmedia_snd_stream *stream)
{
  OSStatus status;
  AQStruct *aq;

  TRACE_((THIS_FILE, "pjmedia_snd_stream_stop."));
  if (stream->dir & PJMEDIA_DIR_PLAYBACK)
  {
    TRACE_((THIS_FILE, "Stopping playback stream"));
    aq = stream->play_strm;
    status = AudioQueueStop (aq->queue, true);
    if (status)
      PJ_LOG(1, (THIS_FILE, "Stopping playback stream error %d", status));
  }
  if (stream->dir & PJMEDIA_DIR_CAPTURE)
  {
    TRACE_((THIS_FILE, "Stopping capture stream"));
    aq = stream->rec_strm;
    status = AudioQueueStop (aq->queue, true);
    if (status)
      PJ_LOG(1, (THIS_FILE, "Stopping capture stream error %d", status));
  }

  // Now that recording has stopped, deactivate the audio session
  status = AudioSessionSetActive(false);
  if (status)
  {
    PJ_LOG(1, (THIS_FILE,
           "AudioSessionSetActive err %d\n", status));
    // return PJMEDIA_ERROR; // FIXME return ???
  }

  return PJ_SUCCESS;
}

/**
 */
PJ_DEF(pj_status_t) pjmedia_snd_stream_get_info(pjmedia_snd_stream *strm,
                                                pjmedia_snd_stream_info *pi)
{
  PJ_ASSERT_RETURN(strm && pi, PJ_EINVAL);
  TRACE_((THIS_FILE, "pjmedia_snd_stream_get_info."));

  pj_bzero(pi, sizeof(pjmedia_snd_stream_info));
  pi->dir = strm->dir;
  pi->play_id = strm->play_id;
  pi->rec_id = strm->rec_id;
  pi->clock_rate = strm->clock_rate;
  pi->channel_count = strm->channel_count;
  pi->samples_per_frame = strm->samples_per_frame;
  pi->bits_per_sample = strm->bits_per_sample;

  Float32 latency;
  UInt32 size = sizeof(latency);
  AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputLatency, &size, &latency);
  pi->rec_latency = latency * iphone_snd_dev_info.default_samples_per_sec;
  TRACE_((THIS_FILE, "pjmedia_snd_stream_get_info rec %f %d.", latency, pi->rec_latency));
  pi->rec_latency = 0;
  AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputLatency, &size, &latency);
  pi->play_latency = latency * iphone_snd_dev_info.default_samples_per_sec;
  TRACE_((THIS_FILE, "pjmedia_snd_stream_get_info play %f %d.", latency, pi->play_latency));
  pi->play_latency = 0;

  return PJ_SUCCESS;
}

PJ_DEF(pj_status_t) pjmedia_snd_stream_close(pjmedia_snd_stream *stream)
{
  OSStatus status;
  AQStruct *aq;

  TRACE_((THIS_FILE, "pjmedia_snd_stream_close."));

  if (stream->dir & PJMEDIA_DIR_PLAYBACK)
  {
    TRACE_((THIS_FILE, "Disposing playback stream"));
    aq = stream->play_strm;

    status = AudioQueueDispose (aq->queue, true);
    if (status)
      PJ_LOG(1, (THIS_FILE, "Disposing playback stream error %d", status));
    pj_bzero(aq, sizeof(stream->play_strm));
  }
  if (stream->dir & PJMEDIA_DIR_CAPTURE)
  {
    TRACE_((THIS_FILE, "Disposing capture stream"));
    aq = stream->rec_strm;

    status = AudioQueueDispose (aq->queue, true);
    if (status)
      PJ_LOG(1, (THIS_FILE, "Disposing capture stream error %d", status));
    pj_bzero(aq, sizeof(stream->rec_strm));
  }

#if KEEP_AUDIO_CATEGORY
  AudioSessionSetProperty(kAudioSessionProperty_AudioCategory,
                          sizeof(stream->prevAudioSessionCategory),
                          &stream->prevAudioSessionCategory);
#endif

  pj_pool_release(stream->pool);
  pj_bzero(stream, sizeof(pjmedia_snd_stream));

  return PJ_SUCCESS;
}

/*
 * Set sound latency.
 */
PJ_DEF(pj_status_t) pjmedia_snd_set_latency(unsigned input_latency,
                                            unsigned output_latency)
{
/*
  snd_input_latency = (input_latency == 0 ? PJMEDIA_SND_DEFAULT_REC_LATENCY : input_latency);
  snd_output_latency = (output_latency == 0 ? PJMEDIA_SND_DEFAULT_PLAY_LATENCY : output_latency);
*/
  /* Nothing to do */
  PJ_UNUSED_ARG(input_latency);
  PJ_UNUSED_ARG(output_latency);

  return PJ_SUCCESS;
}

#if 0
/**
 */
static pj_status_t pjmedia_snd_stream_pause(pjmedia_snd_stream *stream)
{
  OSStatus status;
  AQStruct *aq;

  TRACE_((THIS_FILE, "pjmedia_snd_stream_pause."));
  if (stream->dir & PJMEDIA_DIR_PLAYBACK)
  {
    PJ_LOG(5,(THIS_FILE, "Pausing playback stream"));
    aq = stream->play_strm;
    status = AudioQueuePause (aq->queue);
    if (status)
      PJ_LOG(1, (THIS_FILE, "Pausing playback stream error %d", status));
  }
  if (stream->dir & PJMEDIA_DIR_CAPTURE)
  {
    PJ_LOG(5,(THIS_FILE, "Pausing capture stream"));
    aq = stream->rec_strm;
    status = AudioQueuePause (aq->queue);
    if (status)
      PJ_LOG(1, (THIS_FILE, "Pausing capture stream error %d", status));
  }

  // Now that recording has stopped, deactivate the audio session
  AudioSessionSetActive(false);

  return PJ_SUCCESS;
}

/**
 */
static pj_status_t pjmedia_snd_stream_resume(pjmedia_snd_stream *stream)
{
  OSStatus status;
  AQStruct *aq;

  TRACE_((THIS_FILE, "pjmedia_snd_stream_resume."));

  // before resuming, set the audio session category and activate it
  audioSessionCategory(stream->dir);

  AudioSessionSetActive (true);

  if (stream->dir & PJMEDIA_DIR_PLAYBACK)
  {
    PJ_LOG(1,(THIS_FILE, "Resuming playback stream"));
    aq = stream->play_strm;
    status = AudioQueueStart (aq->queue, NULL);
    if (status)
      PJ_LOG(1, (THIS_FILE, "Resuming playback stream error %d", status));
  }
  if (stream->dir & PJMEDIA_DIR_CAPTURE)
  {
    PJ_LOG(1,(THIS_FILE, "Resuming capture stream"));
    aq = stream->rec_strm;
    status = AudioQueueStart (aq->queue, NULL);
    if (status)
      PJ_LOG(1, (THIS_FILE, "Resuming capture stream error %d", status));
  }

  return PJ_SUCCESS;
}
#endif

#endif	/* PJMEDIA_AUDIO_LEG_HAS_AUDIOQUEUE */
