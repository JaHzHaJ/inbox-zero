"use client";

import { useCallback, useEffect, useState } from "react";
import { useAction } from "next-safe-action/hooks";
import { SettingCard } from "@/components/SettingCard";
import { LoadingContent } from "@/components/LoadingContent";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { useEmailAccountFull } from "@/hooks/useEmailAccountFull";
import { updateDraftFormattingAction } from "@/utils/actions/settings";
import { createSettingActionErrorHandler } from "@/utils/actions/error-handling";
import { toastSuccess } from "@/components/Toast";

/**
 * Police des brouillons rediges par l'assistant. Laisser vide pour retomber sur
 * la police par defaut du fournisseur (Aptos 12 pt cote Outlook).
 */
export function DraftFormattingSetting() {
  const { data, isLoading, error, mutate } = useEmailAccountFull();
  const [open, setOpen] = useState(false);
  const [police, setPolice] = useState("");
  const [taille, setTaille] = useState("");

  // Recharge les valeurs a l'ouverture, pour ne pas garder une saisie abandonnee.
  useEffect(() => {
    if (!open) return;
    setPolice(data?.draftFontFamily ?? "");
    setTaille(data?.draftFontSize ? String(data.draftFontSize) : "");
  }, [open, data?.draftFontFamily, data?.draftFontSize]);

  const { execute, isPending } = useAction(
    updateDraftFormattingAction.bind(null, data?.id ?? ""),
    {
      onSuccess: () => {
        mutate();
        setOpen(false);
        toastSuccess({
          description: "Mise en forme des brouillons enregistrée",
        });
      },
      onError: createSettingActionErrorHandler({
        mutate,
        prefix: "Enregistrement impossible",
      }),
    },
  );

  const enregistrer = useCallback(() => {
    const tailleSaisie = Number.parseInt(taille, 10);

    execute({
      fontFamily: police.trim() || null,
      fontSize: Number.isFinite(tailleSaisie) ? tailleSaisie : null,
    });
  }, [execute, police, taille]);

  const resume =
    data?.draftFontFamily && data?.draftFontSize
      ? `${data.draftFontFamily} ${data.draftFontSize} pt`
      : "Police par défaut";

  return (
    <SettingCard
      title="Police des brouillons"
      description="Police utilisée pour les réponses rédigées par l'assistant. La signature reprend la même police."
      right={
        <LoadingContent
          loading={isLoading}
          error={error}
          loadingComponent={<Skeleton className="h-8 w-32" />}
        >
          <Dialog open={open} onOpenChange={setOpen}>
            <DialogTrigger asChild>
              <Button variant="outline" size="sm">
                {resume}
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Police des brouillons</DialogTitle>
                <DialogDescription>
                  Laisser les deux champs vides pour utiliser la police par
                  défaut d'Outlook.
                </DialogDescription>
              </DialogHeader>

              <div className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="police-brouillon">Police</Label>
                  <Input
                    id="police-brouillon"
                    value={police}
                    onChange={(e) => setPolice(e.target.value)}
                    placeholder="Garamond, serif"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor="taille-brouillon">Taille (points)</Label>
                  <Input
                    id="taille-brouillon"
                    type="number"
                    min={6}
                    max={48}
                    value={taille}
                    onChange={(e) => setTaille(e.target.value)}
                    placeholder="11"
                  />
                </div>

                <Button onClick={enregistrer} loading={isPending}>
                  Enregistrer
                </Button>
              </div>
            </DialogContent>
          </Dialog>
        </LoadingContent>
      }
    />
  );
}
