export const checkoutReturnState=(order,terms)=>({order,terms});

export const shouldRestorePreparedCheckout=(state,orderId)=>
 Boolean(state?.order?.order_id&&state.order.order_id===orderId&&state?.terms?.terms_id);
