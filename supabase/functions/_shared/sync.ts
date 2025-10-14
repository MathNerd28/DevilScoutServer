import { PostgrestError } from "supabase";
import { PromisePool } from "promise-pool";
import { Response } from "express";

// maximum number of concurrent API/DB requests
const CONCURRENCY = 8;

export type SyncResult = {
  successCount: number;
  errors: string[];
};

export function sendSyncResult(
  result: SyncResult,
  res: Response,
) {
  res.status(
    result.errors.length == 0 ? 200 : result.successCount == 0 ? 500 : 207,
  );
  res.send(result);
}

export async function syncBatch<T, U>(
  items: Iterable<T>,
  fetchFn: (item: T) => Promise<U | null>,
  updateFn: (
    item: T,
    data: U,
  ) => PromiseLike<{ error: PostgrestError | null }>,
): Promise<SyncResult> {
  const { results, errors } = await PromisePool
    .for(items)
    .withConcurrency(CONCURRENCY)
    .process(async (item) => {
      const payload = await fetchFn(item);
      if (payload == null) return;

      const { error } = await updateFn(item, payload);
      if (error) {
        console.log(error);
        throw error;
      }
    });

  return {
    successCount: Math.max(results.length - errors.length, 0),
    errors: errors.map((e) => e.message),
  };
}

export async function syncSingle<T, U>(
  fetchFn: () => Promise<U | null>,
  updateFn: (data: U) => PromiseLike<{ error: PostgrestError | null }>,
): Promise<SyncResult> {
  try {
    const payload = await fetchFn();

    if (payload != null) {
      const { error } = await updateFn(payload);
      if (error) {
        console.log(error);
        throw Error(error.details, {cause: error.cause});
      }
    }

    return {
      successCount: 1,
      errors: [],
    };
  } catch (e) {
    let ex: Error;
    if (e instanceof Error) {
      ex = e;
    } else {
      ex = new Error("An unknown error occured");
    }

    return {
      successCount: 0,
      errors: [ex.message],
    };
  }
}
