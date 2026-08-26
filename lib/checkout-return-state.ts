export type PreparedCheckoutState = {
  order: Record<string, unknown> & { order_id?: string };
  terms: Record<string, unknown> & { terms_id?: string };
};

export const checkoutReturnState = (
  order: PreparedCheckoutState['order'],
  terms: PreparedCheckoutState['terms'],
): PreparedCheckoutState => ({order, terms});

export const shouldRestorePreparedCheckout = (
  state: PreparedCheckoutState | null | undefined,
  orderId: string,
) => Boolean(state?.order?.order_id && state.order.order_id === orderId && state?.terms?.terms_id);
