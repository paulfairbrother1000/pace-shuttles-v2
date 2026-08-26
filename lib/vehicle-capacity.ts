export function vehicleCapacity(vehicle: {capacity_seats?: unknown}): number {
  return Number(vehicle.capacity_seats ?? 0);
}
