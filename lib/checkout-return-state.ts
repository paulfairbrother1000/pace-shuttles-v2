export type PreparedCheckoutState={
  order: {order_id?: string; [key:string]: unknown};
  terms: {terms_id?: string; [key:string]: unknown};
};

export const checkoutReturnState=(order:PreparedCheckoutState['order'],terms:PreparedCheckoutState['terms']):PreparedCheckoutState=>({order,terms});

export const shouldRestorePreparedCheckout=(state:PreparedCheckoutState|null|undefined,orderId:string)=>
 Boolean(state?.order?.order_id&&state.order.order_id===orderId&&state?.terms?.terms_id);
