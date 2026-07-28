import { redirect } from "next/navigation";
import { auth } from "@/utils/auth";
import prisma from "@/utils/prisma";

/**
 * Redirige vers une page de l'application SANS connaitre l'identifiant du
 * compte de messagerie.
 *
 * Toutes les pages vivent sous /<emailAccountId>/... Un raccourci exterieur
 * (le portail " Gestion Mails ") ne peut donc pointer vers un ecran precis
 * qu'en connaissant cet identifiant, qui differe d'un compte a l'autre et n'a
 * rien a faire dans un fichier suivi par git.
 *
 * Sans cette route, le portail renvoyait vers la LISTE des comptes : le bouton
 * " Reglages de l'assistant " n'amenait donc pas aux reglages, ce qui donnait
 * l'impression qu'il ne faisait rien.
 *
 *   /aller/automation?tab=settings  ->  /<emailAccountId>/automation?tab=settings
 */
export default async function AllerPage({
  params,
  searchParams,
}: {
  params: Promise<{ chemin?: string[] }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const session = await auth();
  if (!session?.user.id) redirect("/login");

  const compte = await prisma.emailAccount.findFirst({
    where: { userId: session.user.id },
    orderBy: { createdAt: "asc" },
    select: { id: true },
  });
  // Plusieurs comptes ou aucun : la liste reste le bon point de depart.
  if (!compte) redirect("/accounts");

  const { chemin } = await params;
  const destination = chemin?.length ? chemin.join("/") : "automation";

  const parametres = new URLSearchParams();
  for (const [cle, valeur] of Object.entries(await searchParams)) {
    if (typeof valeur === "string") parametres.append(cle, valeur);
    else if (Array.isArray(valeur))
      for (const v of valeur) parametres.append(cle, v);
  }
  const requete = parametres.toString();

  redirect(`/${compte.id}/${destination}${requete ? `?${requete}` : ""}`);
}
