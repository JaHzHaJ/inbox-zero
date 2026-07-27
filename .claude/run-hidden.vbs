' Lance une commande SANS AUCUNE FENETRE.
'
' Pourquoi un script VBS : sous Windows, une tache planifiee en session
' interactive ouvre toujours une console, meme avec "cmd /c" ou
' "powershell -WindowStyle Hidden" (qui font clignoter une fenetre). Passer par
' wscript.exe est la seule methode qui n'affiche rien du tout.
'
' Usage : wscript.exe //B //Nologo run-hidden.vbs <attendre 0|1> <commande> [arguments...]
'   attendre = 1 : rend la main a la fin et propage le code de sortie
'                  (indispensable pour que le Planificateur voie le resultat)
'   attendre = 0 : detache le processus (serveur qui tourne en continu)

Option Explicit

Dim shell, attendre, ligne, i

If WScript.Arguments.Count < 2 Then
  WScript.Quit 2
End If

Set shell = CreateObject("WScript.Shell")
attendre = (WScript.Arguments(0) = "1")

ligne = """" & WScript.Arguments(1) & """"
For i = 2 To WScript.Arguments.Count - 1
  ligne = ligne & " """ & WScript.Arguments(i) & """"
Next

WScript.Quit shell.Run(ligne, 0, attendre)
