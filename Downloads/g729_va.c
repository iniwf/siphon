/* $Id$ */
/*
 * Copyright (C) 2009 Samuel Vinson <samuelv0304@gmail.com>
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

#include <pjmedia/codec.h>
#include <pjmedia/alaw_ulaw.h>
#include <pjmedia/endpoint.h>
#include <pjmedia/errno.h>
#include <pjmedia/port.h>
#include <pjmedia/plc.h>
#include <pjmedia/silencedet.h>
#include <pj/pool.h>
#include <pj/string.h>
#include <pj/assert.h>
#include <pj/log.h>

#if defined(PJMEDIA_HAS_VA_G729_CODEC) && (PJMEDIA_HAS_VA_G729_CODEC!=0)

#include <g729/typedef.h>
#include <g729/g729ab_if.h>

//#define THIS_FILE       "g729_va.c"

/* We removed PLC in 0.6 (and re-enabled it again in 0.9!) */
#define PLC_DISABLED	0


#define G729_BPS	    8000

/* Prototypes for G729 factory */
static pj_status_t g729_test_alloc( pjmedia_codec_factory *factory,
				    const pjmedia_codec_info *id );
static pj_status_t g729_default_attr( pjmedia_codec_factory *factory,
				      const pjmedia_codec_info *id,
				      pjmedia_codec_param *attr );
static pj_status_t g729_enum_codecs (pjmedia_codec_factory *factory,
				     unsigned *count,
				     pjmedia_codec_info codecs[]);
static pj_status_t g729_alloc_codec( pjmedia_codec_factory *factory,
				     const pjmedia_codec_info *id,
				     pjmedia_codec **p_codec);
static pj_status_t g729_dealloc_codec( pjmedia_codec_factory *factory,
				       pjmedia_codec *codec );

/* Prototypes for G729 implementation. */
static pj_status_t  g729_init( pjmedia_codec *codec,
			       pj_pool_t *pool );
static pj_status_t  g729_open( pjmedia_codec *codec,
			       pjmedia_codec_param *attr );
static pj_status_t  g729_close( pjmedia_codec *codec );
static pj_status_t  g729_modify(pjmedia_codec *codec,
			        const pjmedia_codec_param *attr );
static pj_status_t  g729_parse(pjmedia_codec *codec,
			       void *pkt,
			       pj_size_t pkt_size,
			       const pj_timestamp *timestamp,
			       unsigned *frame_cnt,
			       pjmedia_frame frames[]);
static pj_status_t  g729_encode( pjmedia_codec *codec,
				 const struct pjmedia_frame *input,
				 unsigned output_buf_len,
				 struct pjmedia_frame *output);
static pj_status_t  g729_decode( pjmedia_codec *codec,
				 const struct pjmedia_frame *input,
				 unsigned output_buf_len,
				 struct pjmedia_frame *output);
#if !PLC_DISABLED
static pj_status_t  g729_recover( pjmedia_codec *codec,
				  unsigned output_buf_len,
				  struct pjmedia_frame *output);
#endif

/* Definition for G729 codec operations. */
static pjmedia_codec_op g729_op =
{
    &g729_init,
    &g729_open,
    &g729_close,
    &g729_modify,
    &g729_parse,
    &g729_encode,
    &g729_decode,
#if !PLC_DISABLED
    &g729_recover
#else
    NULL
#endif
};

/* Definition for G729 codec factory operations. */
static pjmedia_codec_factory_op g729_factory_op =
{
    &g729_test_alloc,
    &g729_default_attr,
    &g729_enum_codecs,
    &g729_alloc_codec,
    &g729_dealloc_codec
};

/* G729 factory private data */
static struct g729_factory
{
    pjmedia_codec_factory	base;
    pjmedia_endpt	       *endpt;
    pj_pool_t		       *pool;
    pj_mutex_t		       *mutex;
    pjmedia_codec		codec_list;
} g729_factory;

/* G729 codec private data. */
struct g729_private
{
    pj_pool_t   *pool;        /**< Pool for each instance.    */

    void	*encoder; /**< Encoder state.		    */
    void	*decoder; /**< Decoder state.		    */

    unsigned		 pt;
#if !PLC_DISABLED
    pj_bool_t		 plc_enabled;
    pjmedia_plc		*plc;
#endif
    pj_bool_t		 vad_enabled; /**< VAD enabled flag.	    */
    pjmedia_silence_det *vad; /**< PJMEDIA VAD engine, NULL if
						 codec has internal VAD.    */
    pj_timestamp	 last_tx;   /**< Timestamp of last transmit.*/
};


PJ_DEF(pj_status_t) pjmedia_codec_g729_init(pjmedia_endpt *endpt)
{
    pjmedia_codec_mgr *codec_mgr;
    pj_status_t status;

    if (g729_factory.endpt != NULL) {
	/* Already initialized. */
	return PJ_SUCCESS;
    }

    /* Init factory */
    g729_factory.base.op = &g729_factory_op;
    g729_factory.base.factory_data = NULL;
    g729_factory.endpt = endpt;

    pj_list_init(&g729_factory.codec_list);

    /* Create pool */
    g729_factory.pool = pjmedia_endpt_create_pool(endpt, "g729", 4000, 4000);
    if (!g729_factory.pool)
	return PJ_ENOMEM;

    /* Create mutex. */
    status = pj_mutex_create_simple(g729_factory.pool, "g729",
				    &g729_factory.mutex);
    if (status != PJ_SUCCESS)
	goto on_error;

    /* Get the codec manager. */
    codec_mgr = pjmedia_endpt_get_codec_mgr(endpt);
    if (!codec_mgr) {
	return PJ_EINVALIDOP;
    }

    /* Register codec factory to endpoint. */
    status = pjmedia_codec_mgr_register_factory(codec_mgr,
						&g729_factory.base);
    if (status != PJ_SUCCESS)
	return status;


    return PJ_SUCCESS;

on_error:
    if (g729_factory.mutex) {
	pj_mutex_destroy(g729_factory.mutex);
	g729_factory.mutex = NULL;
    }
    if (g729_factory.pool) {
	pj_pool_release(g729_factory.pool);
	g729_factory.pool = NULL;
    }
    return status;
}

PJ_DEF(pj_status_t) pjmedia_codec_g729_deinit(void)
{
    pjmedia_codec_mgr *codec_mgr;
    pj_status_t status;

    if (g729_factory.endpt == NULL) {
	/* Not registered. */
	return PJ_SUCCESS;
    }

    /* Lock mutex. */
    pj_mutex_lock(g729_factory.mutex);

    /* Get the codec manager. */
    codec_mgr = pjmedia_endpt_get_codec_mgr(g729_factory.endpt);
    if (!codec_mgr) {
	g729_factory.endpt = NULL;
	pj_mutex_unlock(g729_factory.mutex);
	return PJ_EINVALIDOP;
    }

    /* Unregister G729 codec factory. */
    status = pjmedia_codec_mgr_unregister_factory(codec_mgr,
						  &g729_factory.base);
    g729_factory.endpt = NULL;

    /* Destroy mutex. */
    pj_mutex_destroy(g729_factory.mutex);
    g729_factory.mutex = NULL;


    /* Release pool. */
    pj_pool_release(g729_factory.pool);
    g729_factory.pool = NULL;


    return status;
}

static pj_status_t g729_test_alloc(pjmedia_codec_factory *factory,
				   const pjmedia_codec_info *id )
{
    PJ_UNUSED_ARG(factory);

    /* Check payload type. */
    if (id->pt != PJMEDIA_RTP_PT_G729)
      return PJMEDIA_CODEC_EUNSUP;

    return PJ_SUCCESS;
}

static pj_status_t g729_default_attr (pjmedia_codec_factory *factory,
				      const pjmedia_codec_info *id,
				      pjmedia_codec_param *attr )
{
    PJ_UNUSED_ARG(factory);

    pj_bzero(attr, sizeof(pjmedia_codec_param));
    attr->info.clock_rate = 8000;
    attr->info.channel_cnt = 1;
    attr->info.avg_bps = G729_BPS;
    attr->info.max_bps = G729_BPS;
    attr->info.pcm_bits_per_sample = 16;
    attr->info.frm_ptime = 10;
    attr->info.pt = PJMEDIA_RTP_PT_G729;

    /* Set default frames per packet to 2 (or 20ms) */
    //attr->setting.frm_per_pkt = 2;
    attr->setting.frm_per_pkt = 1;

#if !PLC_DISABLED
    /* Enable plc by default. */
    attr->setting.plc = 1;
#endif

    /* Enable VAD by default. */
    attr->setting.vad = 1;

    /* Default all other flag bits disabled. */
//#ifndef G729B
    attr->setting.dec_fmtp.cnt = 1;
    attr->setting.dec_fmtp.param[0].name = pj_str("annexb");
    attr->setting.dec_fmtp.param[0].val = pj_str("no");

    //attr->setting.enc_fmtp.cnt = 1;
    //attr->setting.enc_fmtp.param[0].name = pj_str("annexb");
    //attr->setting.enc_fmtp.param[0].val = pj_str("no");
//#endif

    return PJ_SUCCESS;
}

static pj_status_t g729_enum_codecs(pjmedia_codec_factory *factory,
				    unsigned *max_count,
				    pjmedia_codec_info codecs[])
{
    PJ_UNUSED_ARG(factory);
	PJ_ASSERT_RETURN(codecs && *max_count > 0, PJ_EINVAL);

	pj_bzero(&codecs[0], sizeof(pjmedia_codec_info));
	codecs[0].type = PJMEDIA_TYPE_AUDIO;
	codecs[0].pt = PJMEDIA_RTP_PT_G729;
	codecs[0].encoding_name = pj_str("G729");
	codecs[0].clock_rate = 8000;
	codecs[0].channel_cnt = 1;

    *max_count = 1;

    return PJ_SUCCESS;
}

static pj_status_t g729_alloc_codec( pjmedia_codec_factory *factory,
				     const pjmedia_codec_info *id,
				     pjmedia_codec **p_codec)
{
    pjmedia_codec *codec = NULL;
    pj_status_t status;
    pj_pool_t *pool;

    PJ_ASSERT_RETURN(factory && id && p_codec, PJ_EINVAL);
    PJ_ASSERT_RETURN(factory==&g729_factory.base, PJ_EINVAL);

    /* Lock mutex. */
    pj_mutex_lock(g729_factory.mutex);

    /* Allocate new codec if no more is available */
    if (pj_list_empty(&g729_factory.codec_list)) {
	struct g729_private *codec_priv;

  /* Create pool for codec instance */
  pool = pjmedia_endpt_create_pool(g729_factory.endpt, "g729codec", 512, 512);

	codec = PJ_POOL_ALLOC_T(pool, pjmedia_codec);
	codec_priv = PJ_POOL_ZALLOC_T(pool, struct g729_private);
	if (!codec || !codec_priv) {
	  pj_pool_release(pool);
	    pj_mutex_unlock(g729_factory.mutex);
	    return PJ_ENOMEM;
	}

	codec_priv->pool = pool;
	/* Set the payload type */
	codec_priv->pt = id->pt;

#if !PLC_DISABLED
	/* Create PLC, always with 10ms ptime */
	status = pjmedia_plc_create(pool, 8000, 80, 0, &codec_priv->plc);
	if (status != PJ_SUCCESS) {
	  pj_pool_release(pool);
	    pj_mutex_unlock(g729_factory.mutex);
	    return status;
	}
#endif

	/* Create VAD */
	status = pjmedia_silence_det_create(g729_factory.pool,
					    8000, 80,
					    &codec_priv->vad);
	if (status != PJ_SUCCESS) {
	    pj_mutex_unlock(g729_factory.mutex);
	    return status;
	}

	codec->factory = factory;
	codec->op = &g729_op;
	codec->codec_data = codec_priv;
    } else {
	codec = g729_factory.codec_list.next;
	pj_list_erase(codec);
    }

    /* Zero the list, for error detection in g729_dealloc_codec */
    codec->next = codec->prev = NULL;

    *p_codec = codec;

    /* Unlock mutex. */
    pj_mutex_unlock(g729_factory.mutex);

    return PJ_SUCCESS;
}

static pj_status_t g729_dealloc_codec(pjmedia_codec_factory *factory,
				      pjmedia_codec *codec )
{
    struct g729_private *priv = (struct g729_private*) codec->codec_data;
    int i = 0;

    PJ_ASSERT_RETURN(factory && codec, PJ_EINVAL);
    PJ_ASSERT_RETURN(factory==&g729_factory.base, PJ_EINVAL);

    /* Check that this node has not been deallocated before */
    pj_assert (codec->next==NULL && codec->prev==NULL);
    if (codec->next!=NULL || codec->prev!=NULL) {
	return PJ_EINVALIDOP;
    }

    /* Close codec, if it's not closed. */
    g729_close(codec);

#if !PLC_DISABLED
    /* Clear left samples in the PLC, since codec+plc will be reused
     * next time.
     */
    for (i=0; i<2; ++i) {
	pj_int16_t frame[80];
	pjmedia_zero_samples(frame, PJ_ARRAY_SIZE(frame));
	pjmedia_plc_save(priv->plc, frame);
    }
#else
    PJ_UNUSED_ARG(i);
    PJ_UNUSED_ARG(priv);
#endif

    /* Re-init silence_period */
    pj_set_timestamp32(&priv->last_tx, 0, 0);

    /* Lock mutex. */
    pj_mutex_lock(g729_factory.mutex);

    /* Insert at the back of the list */
    pj_list_insert_before(&g729_factory.codec_list, codec);

    /* Unlock mutex. */
    pj_mutex_unlock(g729_factory.mutex);

    pj_pool_release(priv->pool);

    return PJ_SUCCESS;
}

static pj_status_t g729_init( pjmedia_codec *codec, pj_pool_t *pool )
{
    /* There's nothing to do here really */
    PJ_UNUSED_ARG(codec);
    PJ_UNUSED_ARG(pool);

    return PJ_SUCCESS;
}

static pj_status_t g729_open(pjmedia_codec *codec,
			     pjmedia_codec_param *attr )
{
    struct g729_private *priv = (struct g729_private*) codec->codec_data;
    pj_pool_t *pool;

    priv->pt = attr->info.pt;
    pool = priv->pool;

#ifndef G729B
    /* PREPARING THE ENCODER */
    priv->encoder = pj_pool_zalloc(pool, E_IF_g729a_queryBlockSize());
	if (!priv->encoder)
		return PJMEDIA_CODEC_EFAILED;
    if (E_IF_g729a_init(priv->encoder))
    	return PJMEDIA_CODEC_EFAILED;

    /* PREPARING THE DECODER */
    priv->decoder = pj_pool_zalloc(pool, D_IF_g729a_queryBlockSize());
	if (!priv->decoder)
		return PJMEDIA_CODEC_EFAILED;
    if (D_IF_g729a_init(priv->decoder))
		return PJMEDIA_CODEC_EFAILED;
#else
  /* PREPARING THE ENCODER */
  priv->encoder = pj_pool_zalloc(pool, E_IF_g729ab_queryBlockSize());
	if (!priv->encoder)
		return PJMEDIA_CODEC_EFAILED;
    if (E_IF_g729ab_init(priv->encoder))
    	return PJMEDIA_CODEC_EFAILED;

    /* PREPARING THE DECODER */
    priv->decoder = pj_pool_zalloc(pool, D_IF_g729ab_queryBlockSize());
	if (!priv->decoder)
		return PJMEDIA_CODEC_EFAILED;
    if (D_IF_g729ab_init(priv->decoder))
		return PJMEDIA_CODEC_EFAILED;
#endif

#if !PLC_DISABLED
    priv->plc_enabled = (attr->setting.plc != 0);
#endif
    priv->vad_enabled = (attr->setting.vad != 0);
    return PJ_SUCCESS;
}

static pj_status_t g729_close( pjmedia_codec *codec )
{
  PJ_UNUSED_ARG(codec);

  return PJ_SUCCESS;
}

static pj_status_t  g729_modify(pjmedia_codec *codec,
			        const pjmedia_codec_param *attr )
{
    struct g729_private *priv = (struct g729_private*) codec->codec_data;

    if (attr->info.pt != priv->pt)
	return PJMEDIA_EINVALIDPT;

#if !PLC_DISABLED
    priv->plc_enabled = (attr->setting.plc != 0);
#endif
    priv->vad_enabled = (attr->setting.vad != 0);

    return PJ_SUCCESS;
}

static pj_status_t  g729_parse( pjmedia_codec *codec,
				void *pkt,
				pj_size_t pkt_size,
				const pj_timestamp *ts,
				unsigned *frame_cnt,
				pjmedia_frame frames[])
{
    unsigned count = 0;

    PJ_UNUSED_ARG(codec);

    PJ_ASSERT_RETURN(ts && frame_cnt && frames, PJ_EINVAL);

    while (pkt_size >= L_PACKED_G729A /* L_PACKED_G729AB */ && count < *frame_cnt) {
	frames[count].type = PJMEDIA_FRAME_TYPE_AUDIO;
	frames[count].buf = pkt;
	frames[count].size = L_PACKED_G729A; // L_PACKED_G729AB
	frames[count].timestamp.u64 = ts->u64 + 80 * count;

	pkt = ((char*)pkt) + L_PACKED_G729A /* L_PACKED_G729AB */;
	pkt_size -= L_PACKED_G729A /* L_PACKED_G729AB */;

	++count;
    }

    *frame_cnt = count;
    return PJ_SUCCESS;
}

static pj_status_t  g729_encode(pjmedia_codec *codec,
				const struct pjmedia_frame *input,
				unsigned output_buf_len,
				struct pjmedia_frame *output)
{
    struct g729_private *priv = (struct g729_private*) codec->codec_data;
    pj_int16_t *pcm_in;
    unsigned in_size;
#ifndef G729B
    UWord8 bitstream[L_PACKED_G729A];
#else
    UWord8 bitstream[L_PACKED_G729AB];
#endif
    int nb;

  pj_assert(priv && input && output);

  pcm_in = (pj_int16_t*)input->buf;
  in_size = input->size;

  PJ_ASSERT_RETURN(in_size % 160 == 0, PJMEDIA_CODEC_EPCMFRMINLEN);
#ifndef G729B
  PJ_ASSERT_RETURN(output_buf_len >= L_PACKED_G729A * in_size/160,
#else
  //PJ_ASSERT_RETURN(output_buf_len >= L_PACKED_G729AB * in_size/FRAME_SIZE,
  PJ_ASSERT_RETURN(output_buf_len >= L_PACKED_G729A * in_size/160,
                   PJMEDIA_CODEC_EFRMTOOSHORT);
#endif

//#ifndef G729B
    /* Detect silence if VAD is enabled */
    if (priv->vad_enabled) {
	pj_bool_t is_silence;
	pj_int32_t silence_period;

	silence_period = pj_timestamp_diff32(&priv->last_tx,
					     &input->timestamp);

	is_silence = pjmedia_silence_det_detect(priv->vad,
						(const pj_int16_t*) input->buf,
						(input->size >> 1), NULL);
	if (is_silence &&
	    (PJMEDIA_CODEC_MAX_SILENCE_PERIOD == -1 ||
	     silence_period < PJMEDIA_CODEC_MAX_SILENCE_PERIOD*8000/1000))
	{
	    output->type = PJMEDIA_FRAME_TYPE_NONE;
	    output->buf = NULL;
	    output->size = 0;
	    output->timestamp = input->timestamp;
	    return PJ_SUCCESS;
	} else {
	    priv->last_tx = input->timestamp;
	}
    }
//#endif

    /* Encode */
	output->size = 0;

    while (in_size >= 160)
    {
#ifndef G729B
	    E_IF_g729a_encode(priv->encoder,pcm_in, (unsigned char*)output->buf+output->size,&nb);
#else
		  //E_IF_g729ab_encode(priv->encoder,pcm_in, (unsigned char*)output->buf+output->size,
			//			   &nb, priv->vad_enabled);
			E_IF_g729ab_encode(priv->encoder,pcm_in, bitstream, &nb, 0);
			nb -= 1;
			pj_memcpy(output->buf+output->size, &bitstream[1], nb);
#endif

		pcm_in += 80;
		output->size += nb;
		in_size -= 160;
    }

    output->type = PJMEDIA_FRAME_TYPE_AUDIO;
    output->timestamp = input->timestamp;

    return PJ_SUCCESS;
}

static pj_status_t  g729_decode(pjmedia_codec *codec,
				const struct pjmedia_frame *input,
				unsigned output_buf_len,
				struct pjmedia_frame *output)
{
    struct g729_private *priv = (struct g729_private*) codec->codec_data;
#ifndef G729B
    UWord8 bitstream[L_PACKED_G729A];
#else
    UWord8 bitstream[L_PACKED_G729AB];
#endif
    //Word32 error;

    pj_assert(priv != NULL);
    PJ_ASSERT_RETURN(input && output, PJ_EINVAL);

    /* Check output buffer length */
	  if (output_buf_len < 160)
      return PJMEDIA_CODEC_EPCMTOOSHORT;
#ifndef G729B
    if (input->size < L_PACKED_G729A)
      return PJMEDIA_CODEC_EFRMTOOSHORT;
#else
    //if (input->size < L_PACKED_G729AB)
    if (input->size < L_PACKED_G729A)
      return PJMEDIA_CODEC_EFRMTOOSHORT;
#endif

    /* Decode */
#ifndef G729B
	D_IF_g729a_decode(priv->decoder, (unsigned char*)input->buf, (short*)output->buf, 0);
#else
	//D_IF_g729ab_decode(priv->decoder, (unsigned char*)input->buf, (short*)output->buf, 0);
	bitstream[0] = 2;
  pj_memcpy(&bitstream[1], input->buf, L_PACKED_G729A);
  D_IF_g729ab_decode(priv->decoder, bitstream, (Word16*)output->buf, 0);
#endif

    output->type = PJMEDIA_FRAME_TYPE_AUDIO;
	  output->size = 160;
    output->timestamp = input->timestamp;

#if !PLC_DISABLED
    if (priv->plc_enabled)
	pjmedia_plc_save( priv->plc, (pj_int16_t*)output->buf);
#endif

    return PJ_SUCCESS;
}

#if !PLC_DISABLED
static pj_status_t  g729_recover( pjmedia_codec *codec,
				  unsigned output_buf_len,
				  struct pjmedia_frame *output)
{
    struct g729_private *priv = (struct g729_private*) codec->codec_data;

	  PJ_ASSERT_RETURN(priv->plc_enabled, PJ_EINVALIDOP);

    PJ_ASSERT_RETURN(output_buf_len >= 160,
		     PJMEDIA_CODEC_EPCMTOOSHORT);

    pjmedia_plc_generate(priv->plc, (pj_int16_t*)output->buf);
    output->size = 160;

    return PJ_SUCCESS;
}
#endif

#endif	/* PJMEDIA_HAS_VA_G729_CODEC */
