import { describe, it, expect, vi, beforeEach } from "vitest";
import { DigestStatus } from "@/generated/prisma/enums";
import prisma from "@/utils/prisma";
import {
  recupererCreneauxAbandonnes,
  ENVOI_ABANDONNE_MINUTES,
} from "./creneau-abandonne";

vi.mock("@/utils/prisma");

const logger = {
  warn: vi.fn(),
  info: vi.fn(),
  error: vi.fn(),
  trace: vi.fn(),
  with: vi.fn(),
} as never;

describe("recupererCreneauxAbandonnes", () => {
  beforeEach(() => {
    vi.mocked(prisma.digest.updateMany).mockResolvedValue({ count: 0 });
    vi.mocked(prisma.schedule.updateMany).mockResolvedValue({ count: 0 });
  });

  it("ne touche a rien quand aucun envoi n'est reste en cours", async () => {
    vi.mocked(prisma.digest.findMany).mockResolvedValue([]);

    const resultat = await recupererCreneauxAbandonnes(logger);

    expect(resultat).toEqual({ digests: 0, comptes: 0 });
    expect(prisma.digest.updateMany).not.toHaveBeenCalled();
    // Le point important : un planning sain ne doit JAMAIS etre modifie.
    expect(prisma.schedule.updateMany).not.toHaveBeenCalled();
  });

  it("remet les digests en attente et rend le creneau", async () => {
    vi.mocked(prisma.digest.findMany).mockResolvedValue([
      { id: "d1", emailAccountId: "compte1" },
      { id: "d2", emailAccountId: "compte1" },
    ] as never);

    const resultat = await recupererCreneauxAbandonnes(logger);

    // Deux digests, mais un seul compte : le creneau n'est rendu qu'une fois.
    expect(resultat).toEqual({ digests: 2, comptes: 1 });

    expect(prisma.digest.updateMany).toHaveBeenCalledWith({
      where: { id: { in: ["d1", "d2"] } },
      data: { status: DigestStatus.PENDING },
    });

    const appel = vi.mocked(prisma.schedule.updateMany).mock.calls[0][0];
    expect(appel.where?.emailAccountId).toEqual({ in: ["compte1"] });
    // On ne recule que les plannings deja avances : sans cette condition, on
    // rendrait "du maintenant" un creneau parfaitement normal.
    expect(appel.where?.nextOccurrenceAt).toHaveProperty("gt");
  });

  it("ne considere abandonnes que les envois plus vieux que le seuil", async () => {
    vi.mocked(prisma.digest.findMany).mockResolvedValue([]);
    const avant = Date.now();

    await recupererCreneauxAbandonnes(logger);

    const appel = vi.mocked(prisma.digest.findMany).mock.calls[0][0];
    expect(appel?.where?.status).toBe(DigestStatus.PROCESSING);
    const limite = (appel?.where?.updatedAt as { lt: Date }).lt;
    const ecart = avant - limite.getTime();
    // La borne doit tomber a ~30 minutes dans le passe.
    expect(ecart).toBeGreaterThanOrEqual(ENVOI_ABANDONNE_MINUTES * 60 * 1000);
    expect(ecart).toBeLessThan((ENVOI_ABANDONNE_MINUTES + 1) * 60 * 1000);
  });
});
