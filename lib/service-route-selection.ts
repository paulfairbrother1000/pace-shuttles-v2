export type ServiceRouteOption = {
  id: string;
  route_name?: string | null;
  name?: string | null;
};

export function formatServiceRouteChoices(routes: ServiceRouteOption[]) {
  return routes
    .map((route, index) => `${index + 1}. ${route.route_name || route.name || route.id}`)
    .join('\n');
}

export function resolveServiceRouteChoice<T extends ServiceRouteOption>(
  routes: T[],
  choice: string,
): T | null {
  const value = choice.trim();
  if (!/^[1-9]\d*$/.test(value)) return null;
  return routes[Number(value) - 1] ?? null;
}
