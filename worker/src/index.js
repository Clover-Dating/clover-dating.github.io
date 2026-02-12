// Cloudflare Worker — handles POST /api/visit
// Reads geo from Cloudflare's request.cf (no external API needed)
// Inserts into Supabase page_visits via REST API

const regionNames = new Intl.DisplayNames(['en'], { type: 'region' });

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204 });
    }

    const url = new URL(request.url);
    if (request.method === 'POST' && url.pathname === '/api/visit') {
      return handleVisit(request, env);
    }

    return new Response('Not found', { status: 404 });
  },
};

async function handleVisit(request, env) {
  try {
    const body = await request.json();
    const cf = request.cf || {};

    // CF provides country as ISO code (e.g. "US"); derive full name
    const countryCode = cf.country || null;
    let countryName = null;
    if (countryCode) {
      try {
        countryName = regionNames.of(countryCode);
      } catch (_) {
        countryName = countryCode;
      }
    }

    const row = {
      page_path: body.page_path || '/',
      referrer: body.referrer || null,
      platform: body.platform || null,
      city: cf.city || null,
      region: cf.region || null,
      country: countryName,
      country_code: countryCode,
      postal: cf.postalCode || null,
    };

    const res = await fetch(`${env.SUPABASE_URL}/rest/v1/page_visits`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': env.SUPABASE_ANON_KEY,
        'Authorization': `Bearer ${env.SUPABASE_ANON_KEY}`,
        'Prefer': 'return=minimal',
      },
      body: JSON.stringify(row),
    });

    if (!res.ok) {
      const err = await res.text();
      return new Response(JSON.stringify({ error: err }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}
