import { NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';

export const runtime = 'nodejs';
const stripePost = async (path: string, body: URLSearchParams) => {
  const r = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
    cache: 'no-store',
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message || 'Stripe request failed');
  return j;
};
export async function POST(req: Request) {
  try {
    const auth = req.headers.get('authorization') || '';
    const token = auth.replace(/^Bearer\s+/i, '');
    if (!token) return NextResponse.json({ error: 'Sign in required' }, { status: 401 });
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL!,
      anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      service = process.env.SUPABASE_SERVICE_ROLE_KEY!,
      secret = process.env.STRIPE_SECRET_KEY!;
    const missing = [!url && 'NEXT_PUBLIC_SUPABASE_URL', !anon && 'NEXT_PUBLIC_SUPABASE_ANON_KEY', !secret && 'STRIPE_SECRET_KEY'].filter(Boolean) as string[];
    if (missing.length) return NextResponse.json({ error: 'Payment service is not configured', missing }, { status: 503 });
    const userClient = createClient(url, anon, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const {
      data: { user },
    } = await userClient.auth.getUser(token);
    if (!user) return NextResponse.json({ error: 'Sign in required' }, { status: 401 });
    const { orderId } = await req.json();
    const { data, error } = await userClient.rpc('v2_customer_order_payment_context', { p_order_id: orderId });
    if (error || !data?.[0]) return NextResponse.json({ error: error?.message || 'Order not found' }, { status: 404 });
    const o = data[0];
    if (!o.terms_accepted)
      return NextResponse.json(
        {
          error: `Please accept the Pace Shuttles Client Terms & Conditions for ${o.country_name} (version ${o.terms_version}) before payment.`,
        },
        { status: 409 },
      );
    const { error: termsError } = await userClient.rpc('v2_customer_assert_order_terms_accepted', { p_order_id: o.order_id });
    if (termsError) return NextResponse.json({ error: termsError.message }, { status: 409 });
    if (o.payment_status === 'paid')
      return NextResponse.json({
        paid: true,
        url: `/payment/success?order=${o.order_id}`,
      });
    const origin = new URL(req.url).origin;
    const body = new URLSearchParams();
    body.set('mode', 'payment');
    body.set('expires_at', String(Math.floor(Date.now() / 1000) + 30 * 60));
    body.set('success_url', `${origin}/payment/success?order=${o.order_id}&session_id={CHECKOUT_SESSION_ID}`);
    body.set('cancel_url', `${origin}/checkout?order=${o.order_id}`);
    body.set('customer_email', user.email || '');
    body.set('client_reference_id', o.order_id);
    body.set('metadata[order_id]', o.order_id);
    body.set('metadata[booking_id]', o.booking_id);
    body.set('metadata[terms_country]', o.country_name);
    body.set('metadata[terms_version]', o.terms_version);
    body.set('payment_intent_data[metadata][order_id]', o.order_id);
    body.set('payment_intent_data[metadata][terms_version]', o.terms_version);
    body.set('line_items[0][price_data][currency]', String(o.currency || 'USD').toLowerCase());
    body.set('line_items[0][price_data][unit_amount]', String(o.total_cents));
    body.set('line_items[0][price_data][product_data][name]', `${o.pickup_name} → ${o.destination_name}`);
    body.set('line_items[0][price_data][product_data][description]', `${o.seats} seat${o.seats === 1 ? '' : 's'} · Pace Shuttles`);
    body.set('line_items[0][quantity]', '1');
    const session = await stripePost('checkout/sessions', body);
    if (service) {
      const admin = createClient(url, service, {
        auth: { persistSession: false },
      });
      const { error: registerError } = await admin.rpc('v2_system_register_stripe_checkout', { p_order_id: o.order_id, p_session_id: session.id });
      if (registerError) console.error('Stripe checkout registration failed', registerError.message);
    } else console.warn('SUPABASE_SERVICE_ROLE_KEY unavailable; Stripe checkout opened without pre-registration');
    return NextResponse.json({
      url: session.url,
      registrationDeferred: !service,
    });
  } catch (e: any) {
    return NextResponse.json({ error: e.message || 'Unable to start payment' }, { status: 500 });
  }
}
