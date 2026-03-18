# TODO

trixie fixes:
- [ ] sudo rm /etc/issue.d/IP.issue
- [ ] sudo touch /etc/cloud/cloud-init.disabled oder sudo apt remove cloud-guest-utils cloud-init --yes
- [ ] config.txt enable_uart=1 entfernen im firstboot script
- [x] firstboot skripte deaktivieren

initramfs skripte:
- [ ] alle apt und dpkg installationen verhindern im usermode (ram und persistent)
- [ ] neue firstboot daten importieren
- [ ] 
- [ ] bestimmte änderungen nicht im developer mode machen, z.B. splash screens, ...
- [ ] mode datei erstellen (welcher mode ist gestartet?)
- [ ] 

service paket (muss installiert sein):
- [ ] firstboot skript erstellen
- [ ] im ram modus platz generieren (wie original auch)
- [ ] funktionen von original updater und configurator
- [ ] whiptail dialog erstellen
- [ ] commandline befehle mit sudo pin o.ä. 
- [ ] imageauswahl hinzufügen -> symlinks
- [ ] add Sevice output text -> echo "[$SCRIPT_TITLE] TEXT"
- [ ] auto-installer automatisch starten lassen?
- [ ] cleanup für developer mode -> datei für builder erstellen danach
- [ ] imgldr version prüfen im developer modus vor finalisierung
- [ ] 

firstboot skript (immer im normal mode):
- [ ] Alle root ordner außer usr nach var verschieben und verlinken
- [ ] einstellungen direkt ausführen, danach rammodus aktivieren
- [ ] config.txt: enable_uart=1 entfernen
- [ ] 
- [ ] 

imgldr
- [ ] unarmfile funktion (ersetzt datei durch skript mit optionalem infotext)
- [ ] whiptail hinzufügen?
- [ ] imageauswahl hinzufügen wenn kein system.sqfs da aber ordner mit system.sqfs dateien
- [ ] 
- [ ] 

- [ ] Test version 1.4