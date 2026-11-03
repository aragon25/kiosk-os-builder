# TODO

trixie fixes:
- [x] sudo rm /etc/issue.d/IP.issue
- [x] sudo touch /etc/cloud/cloud-init.disabled oder sudo apt remove cloud-guest-utils cloud-init --yes
- [X] (-> in splash gemacht) config.txt enable_uart=1 entfernen im firstboot script
- [x] firstboot skripte deaktivieren

initramfs skripte:
- [x] alle apt und dpkg installationen verhindern im usermode (ram und persistent)
- [x] neue firstboot daten importieren
- [x] bestimmte änderungen nicht im developer mode machen, z.B. splash screens, ...
- [x] mode datei erstellen (welcher mode ist gestartet?)
- [ ] dialog benutzen statt pretty_text
- [ ] update anpassen
- [x] motd skript generieren (siehe kiosk-os-configurator.sh)
- [x] im ram modus platz generieren (wie original auch als service)
- [ ] 

service paket (muss installiert sein):
- [ ] updater script erstellen. evtl auch service
- [ ] whiptail dialog erstellen
- [ ] commandline befehle mit sudo pin o.ä. 
- [ ] imageauswahl hinzufügen -> /CONFIG/image_load
- [ ] auto-installer automatisch starten lassen?
- [ ] cleanup für developer mode -> datei für builder erstellen danach
- [ ] imgldr version prüfen im developer modus vor finalisierung
- [ ] 

- [ ] Test version 1.4