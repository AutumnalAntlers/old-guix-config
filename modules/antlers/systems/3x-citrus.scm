(define-module (antlers systems 3x-citrus)
  #:use-module ((gnu system accounts) #:select (user-account))
  #:use-module ((rnrs base) #:hide (map)) ; what else for?
  #:use-module (antlers channels)
  #:use-module (antlers gexp)
  #:use-module (antlers records)
  #:use-module (antlers sops)
  #:use-module (antlers systems base)
  #:use-module (antlers systems transformations oot-modules)
  #:use-module (antlers systems transformations zfs)
  #:use-module (antlers.tmp variables)
  #:use-module (gnu home services guix)
  #:use-module (gnu)
  #:use-module (guix build-system copy)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix modules)
  #:use-module (guix packages)
  #:use-module (guix profiles)
  #:use-module (guix records)
  #:use-module (guix store)
  #:use-module (guix transformations)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:use-module (nongnu packages linux)
  #:use-module (nongnu system linux-initrd)
  #:use-module (srfi srfi-1)
  #:export (%system))

(use-service-modules shepherd ssh desktop #;xorg)
(use-system-modules  file-systems
                     linux-initrd
                     mapped-devices
                     uuid)
(use-package-modules base
                     bash
                     cryptsetup
                     file-systems
                     freedesktop
                     gawk
                     gnome
                     guile
                     gnupg
                     linux
                     rsync)

;; TODO: linux-firmware

(define %kernel
  (customize-linux
    ;; TODO: Upstream this to base.scm, latest version ZFS supports,
    ;;       has dm-integrity updates.
    #:linux linux-lts ; hopefully lts is ok
    #:configs
    (list "CONFIG_DRM=y"
          "CONFIG_PCI=y"
          "CONFIG_MMU=y"
          "CONFIG_UML"
          "CONFIG_DRM_AMDGPU=y"
          "CONFIG_DYNAMIC_DEBUG=y" ; tmp?
          )))

(define %swap-uuid
  (uuid-bytevector
    (uuid "ab8a9eda-747f-4c4d-badc-7b3e4cff2cab")))

;; XXX: START TEMP
(set! zfs (linux-module-with-kernel %kernel zfs))
(set! plymouth
  (modify-record plymouth
    (arguments => (substitute-keyword-arguments <>
      ((#:configure-flags flags #~'())
       #~(map (lambda (flag)
                (if (string-prefix? "--with-boot-tty=" flag)
                    ;; "--with-boot-tty=/dev/tty7"
                    "--with-boot-tty=/dev/console"
                    flag))
           #$flags))
      ((#:phases phases)
       (with-imported-modules (source-module-closure
                                '((guix build utils)))
         #~(begin
             (use-modules (guix build utils)
                          (ice-9 ftw))
             (modify-phases #$phases
               (add-after 'unpack 'custom-patch
                 (lambda _
                   (substitute* "src/libply-splash-core/ply-device-manager.c"
                     (("udev_device_has_tag \\(device, \"seat\"\\)")
                      "true"))))
               (add-after 'install 'set-theme
                 (lambda _
                   (with-directory-excursion (string-append #$output "/share/plymouth/themes")
                     (map (lambda (f)
                            (unless (member f (list "." ".." "bgrt" "spinner" "text"))
                              (delete-file-recursively f)))
                          (scandir "."))
                     (symlink "bgrt/bgrt.plymouth" "default.plymouth")
                     (substitute* "../plymouthd.defaults"
                       (("^Theme=.*$")
                        "Theme=bgrt\n"))
                     )))))))))))
(set! plymouth
  (modify-record plymouth
    (arguments => (substitute-keyword-arguments <>
      ((#:configure-flags flags #~'())
       #~(map (lambda (flag)
                (if (string-prefix? "--with-boot-tty=" flag)
                    ;; "--with-boot-tty=/dev/tty7"
                    "--with-boot-tty=/dev/console"
                    flag))
           #$flags))
      ((#:phases phases)
       (with-imported-modules (source-module-closure
                                '((guix build utils)))
         #~(begin
             (use-modules (guix build utils)
                          (ice-9 ftw))
             (modify-phases #$phases
               (add-after 'unpack 'custom-patch
                 (lambda _
                   (substitute* "src/libply-splash-core/ply-device-manager.c"
                     (("udev_device_has_tag \\(device, \"seat\"\\)")
                      "true"))))
               (add-after 'install 'set-theme
                 (lambda _
                   (with-directory-excursion (string-append #$output "/share/plymouth/themes")
                     (map (lambda (f)
                            (unless (member f (list "." ".." "bgrt" "spinner" "text"))
                              (delete-file-recursively f)))
                          (scandir "."))
                     (symlink "bgrt/bgrt.plymouth" "default.plymouth")
                     (substitute* "../plymouthd.defaults"
                       (("^Theme=.*$")
                        "Theme=bgrt\n"))
                     )))))))))))
(set! %pseudo-file-system-types
  (cons "zfs" %pseudo-file-system-types))
(define %initrd/import-device-zpool
  #~(lambda (device)
      (let ((zpool (substring device 0 (or (string-index device #\/) 0)))
            (present? (lambda (device)
                        (and (not (zero? (string-length device)))
                             (zero? (system* #$(file-append zfs "/sbin/zfs")
                                             "list" device))))))
        (unless (or (zero? (string-length zpool))
                    (present? device))
          (invoke #$(file-append zfs "/sbin/zpool") "import" zpool)

          ;; TODO: Feels shoe-horned in.
          (map (lambda (dataset)
                 (let ((ds (substring dataset (1+ (string-rindex dataset #\/))))
                       (zpool* (substring dataset 0 (string-rindex dataset #\/))))
                   (when (equal? zpool zpool*)
                     (system* #$(file-append zfs "/sbin/zfs") "load-key"
                              "-L" "file:///system.key"
                              dataset)
                     (when (member ds '("guix-root" "home" "root"))
                       (system* #$(file-append zfs "/sbin/zfs") "rollback"
                                (string-append zpool "/" ds "@blank"))))))
               '("3x-citrus/guix-root"
                 "3x-citrus/home"
                 "3x-citrus/root"
                 "3x-citrus/persist"
                 "3x-citrus/persist-cache"
                 "3x-citrus/var-log"
                 "3x-citrus/var-guix"
                 "3x-citrus/gnu-store"))

          ;; Make swap read-write post-`resume-if-hibernation`
          ;; TODO: Is this really needed?
          (when (equal? zpool "3x-citrus")
            (system*/tty #$(file-append cryptsetup-static "/sbin/cryptsetup ")
                         "close" "3x-citrus-swap")
            (system*/tty #$(file-append cryptsetup-static "/sbin/cryptsetup ")
                         "open" "--key-file" "/system.key"
                         (find-partition-by-luks-uuid #$%swap-uuid)
                         "3x-citrus-swap")

            ;; TODO: Duped code
            (let loop ((i 0))
              (unless (file-exists? "/dev/mapper/3x-citrus-swap")
                (when (zero? (% i 100))
                  (format #t "waiting for /dev/mapper/3x-citrus-swap..."))
                (usleep 10000)
                (unless (> i 2000)
                  (loop (1+ i))))))

          (present? device)))))

(define %initrd/pre-mount
  (with-imported-modules (source-module-closure
                          '((guix build syscalls)
                            (guix build utils)))
    #~(begin
        (use-modules (gnu build file-systems)
                     (gnu build linux-boot)
                     ((guix build syscalls)
                      #:hide (file-system-type))
                     (guix build utils))

        ;; XXX: Major Hack! Enables mounting ZFS datasets via legacy mountpoints.
        ;; `%initrd/import-device-zpool' also unlocks the datasets...
        (let ((orig (@ (gnu build file-systems) canonicalize-device-spec)))
          (set! (@ (gnu build file-systems) canonicalize-device-spec)
            (lambda (spec)
              (let ((device (if (file-system-label? spec)
                                (file-system-label->string spec)
                                spec)))
                (if (and (string? device)
                         (char-set-contains? char-set:letter (string-ref device 0))
                         (#$%initrd/import-device-zpool device))
                    device
                    (orig spec))))))

        (let ((set-path (apply string-append
                          (map (lambda (p)
                                 (apply string-append
                                   (map (lambda (dir)
                                          (string-append "PATH+=:\"" p dir "\"; "))
                                        '("/bin" "/sbin"))))
                               '#$(cons* plymouth
                                         (map specification->package
                                              '("bash"
                                                "coreutils"
                                                "eudev"
                                                "gnupg"
                                                "gzip" ; for viewing config.gz
                                                "util-linux")))))))
          (system* #$(file-append (specification->package "bash") "/bin/bash") "-c"
            (string-append
              set-path
              "export PATH; "
              "LINUX_MODULE_DIRECTORY=\"$(echo -n /gnu/store/*linux-modules*)\"; "
              "export LINUX_MODULE_DIRECTORY; "
              ;; TODO: Yubikey to unlock / GPG keys / Luks master key???
              ;; "EUDEV_RULES_DIRECTORY=\""
              ;; #$(file-append ((@@ (gnu services base) udev-rules-union)
              ;;                 (cons zfs
              ;;                       eudev
              ;;                       (map specification->package
              ;;                            (list "yubikey-personalization"))))
              ;;                "/lib/udev/rules.d")
              ;; "\"; "
              "export EUDEV_RULES_DIRECTORY; "
              "# Don't allow  user to exit via Ctrl-C.
               trap '' SIGINT
               set -m # enable job control?

               # Start plymouthd and show splash
               mkdir /run || true
               udevd --daemon --resolve-names=never
               until [[ -S /run/udev/control ]]; do sleep 0.01; done
               udevadm trigger --action=add
               udevadm settle

               mkdir /run/plymouth || true
               plymouthd --pid-file /run/plymouth/pid --mode=boot
               plymouth show-splash

               try_decrypt () {
                 plymouth ask-for-password         \\
                   | gpg --batch --quiet --no-tty  \\
                         --passphrase-fd 0         \\
                         --output /system.key      \\
                         --decrypt /system.key.gpg
               }
               try_decrypt; until [[ -f /system.key ]]; do sleep 3; try_decrypt; done
               udevadm control -e "))

          ;; Mount `3x-citrus-swap'
          ;; Errno 6 ???? tty???? (--batch????)
          (mkdir-p "/run/cryptsetup/")
          (system*/tty #$(file-append cryptsetup-static "/sbin/cryptsetup")
                       "open" "--readonly" "--key-file" "/system.key"
                       (find-partition-by-luks-uuid #$%swap-uuid)
                       "3x-citrus-swap")

          (let loop ((i 0))
            (unless (file-exists? "/dev/mapper/3x-citrus-swap")
              (when (zero? (% i 100))
                (format #t "waiting for /dev/mapper/3x-citrus-swap..."))
              (usleep 10000)
              (unless (> i 2000)
                (loop (1+ i)))))

          ;; TODO: Add updates to plymouth as we move into the new root?
          (invoke #$(file-append plymouth "/bin/plymouth") "update-root-fs" "--read-write")
          (invoke #$(file-append plymouth "/bin/plymouth") "quit" "--retain-splash")

          (when (member "antlers.repl" (linux-command-line))
            (system*/tty #$(file-append bash "/bin/bash") "-i"))
          ))))

(define (%initrd file-systems . kwargs)
  (apply raw-initrd
    (cons file-systems
          (substitute-keyword-arguments kwargs
            ((#:linux linux)
             #~#$(kernel-with-oot-modules linux
                   (list #~#$zfs:module)))
            ((#:linux-modules modules '())
             (append ((@@ (gnu system linux-initrd) file-system-modules)
                      file-systems)
                     '("dm-integrity" "overlay"
                       ;; Pretty sure one of these will fix dm-integrity..
                       ;; TODO: ...do we need all of them?
                       "aesni_intel" "algif_aead" "af_alg" "crypto_simd"
                       "cryptd" "xor" "dm_crypt" "uas" "authenc" "dm_bufio"
                       "async_xor" "async_tx")
                     modules))
            ((#:pre-mount pre-mount #t)
             #~(begin #$%initrd/pre-mount
                      #$pre-mount))
            ((#:volatile-root? _ #t) #t)))))
;; XXX: END TEMP

(define %system
  (modify-record %graphical-system
    (host-name -> "3x-citrus")
    (kernel -> %kernel)
    (initrd ->
      (lambda (file-systems . kwargs)
        (apply microcode-initrd
          (cons file-systems
                (substitute-keyword-arguments kwargs
                  ((#:initrd _ #t) %initrd))))))
    (bootloader ->
      (bootloader-configuration
        (bootloader grub-efi-bootloader)
        (targets (list (string-append (or guix-altroot "") "/boot/efi")))
        (timeout 2)))
    (swap-devices --> (list
      (swap-space (target "/dev/mapper/3x-citrus-swap"))))
    (file-systems -> (append
      ;; TODO: I'll want /home to be an overlayfs mount too,
      ;;       at least for ~antlers.
      (cons (file-system
              (mount-point "/")
              (device "3x-citrus/guix-root")
              (type "zfs"))
            (map (lambda (ds)
                   (file-system
                     (mount-point
                       (let ((path (substring ds (string-rindex ds #\/))))
                         (string-replace-substring path "-" "/")))
                     (device ds)
                     (type "zfs")
                     (needed-for-boot? #t)))
                 '("3x-citrus/home"
                   "3x-citrus/root"
                   "3x-citrus/persist"
                   "3x-citrus/persist-cache"
                   "3x-citrus/var-log"
                   "3x-citrus/var-guix"
                   "3x-citrus/gnu-store")))
      (list (file-system
              (mount-point "/boot")
              (device (uuid "6f62e623-5aa9-4681-a6da-9e0a68e7fbfb"))
              (type "ext4"))
            (file-system
              (mount-point "/boot/efi")
              (device (uuid "F2A5-60F7" 'fat32))
              (type "vfat")))
      (list (file-system
              (mount-point "/run/sops-guix")
              (device "tmpfs")
              (type "tmpfs")
              (needed-for-boot? #t)
              (options "mode=750")
              (flags '(no-dev no-suid))))
      %base-tmpfs-list
      %base-file-systems))
    (kernel-arguments -> (list
      "resume=/dev/mapper/3x-citrus-swap"
      "splash"
      ;; XXX 2023/06/02: This causes plymouth to hang?
      ;; "console=/dev/tty7"
      "vt.global_cursor_default=0" ; TODO: re-enable during activation?
      ))
    ;; TODO: Add a declarative API, maybe as a service; I want my
    ;;       erasure service to be able to extend this?
    (sudoers-file -> (append-to-plain-file <>
      "Defaults lecture = never"
      "root ALL=(ALL) ALL"
      "%wheel ALL=(ALL) ALL"))
    (services => (append <> (list
      ;; XXX: That's a home service, dummy.
      ;; (simple-service 'channels.scm
      ;;                 home-channels-service-type
      ;;                 %antlers-default-channels)
      (simple-service 'set-hibernation-mode activation-service-type
                      ;; Prevents hibernation issues with `dm-integrity'.
                      #~(with-output-to-file "/sys/power/disk"
                           (lambda _ (format #t "~a" "shutdown"))))
      #;
      (simple-service 'extract-secrets shepherd-root-service-type
        (list
          (shepherd-service
            (documentation "Run the syslog daemon (syslogd).")
            (provision '(sops-guix))
            (requirement '(pam))
            (one-shot? #t)
            (start #~(make-forkexec-constructor
                       (list #$(program-file "sops-guix"
                                 (with-imported-modules `(,@(source-module-closure
                                                             '((guix build utils)))
                                                          (antlers sops))
                                   (with-extensions (list guile-json-4)
                                     #~(begin
                                         (use-modules (antlers sops)
                                                      (guix build utils)
                                                      (json)
                                                      (ice-9 match)
                                                      (ice-9 pretty-print)
                                                      (srfi srfi-1)
                                                      (srfi srfi-43))
                                         (umask #o277)
                                         (map (lambda (pkg)
                                                (setenv "PATH" (string-append pkg "/bin/:" pkg "/sbin/:" (getenv "PATH"))))
                                              '#$(list bash coreutils gnupg))
                                         (when (file-exists? "/run/sops-guix/key.pem")
                                           (delete-file "/run/sops-guix/key.pem"))
                                         (copy-file "/etc/ssh/ssh_host_rsa_key" "/run/sops-guix/key.pem")
                                         (invoke-pipeline
                                           '((#$(file-append (specification->package "openssh") "/bin/ssh-keygen")
                                              "-f" "/run/sops-guix/key.pem"
                                              "-p" "-N" "" "-m" "pem")))
                                         (let* ((dict (with-input-from-file
                                                        #$(local-file "../secret/3x-citrus.json")
                                                        (lambda _ (json->scm))))
                                                (pubkey (invoke-pipeline
                                                          `((#$(file-append (specification->package "gawk") "/bin/gawk")
                                                             "{print $1 \" \" $2}" "/etc/ssh/ssh_host_rsa_key.pub"))))
                                                (recipient (find (lambda (r) (equal? (assoc-ref r "recipient") pubkey))
                                                                 (vector->list (assoc-ref (assoc-ref dict "sops") "ssh_rsa")))))
                                           (when recipient
                                             (let* ((strip-decor `(,#$(file-append (specification->package "sed") "/bin/sed") "-e" "1d" "-e" "$d"))
                                                    (armored-data-key (invoke-pipeline
                                                                        `((,@strip-decor "-e" "s/\\\\n/\\n/g")) ; TODO: It ok if I drop the newline transformation?
                                                                        #:input-strings `(,(assoc-ref recipient "enc"))))
                                                    (armored-privkey (invoke-pipeline
                                                                       `((,@strip-decor "/run/sops-guix/key.pem"))))
                                                    ; Can't store binary data in variables, but can use stdin and proc-sub pipes to carry the unarmored keys
                                                    (data-key (invoke-pipeline
                                                                `(,(read-into "armored_privkey" armored-privkey
                                                                     `(#$(file-append (specification->package "coreutils") "/bin/base64") "-d" "|"
                                                                       #$(file-append (specification->package "openssl") "/bin/openssl") "pkeyutl" "-decrypt"
                                                                       "-inkey" ,(string-append "<(" #$(file-append (specification->package "coreutils") "/bin/base64") " -d <<< \"$armored_privkey\")"))))
                                                                #:input-strings `(,armored-privkey ,armored-data-key)))
                                                    (dict (walk-json-dict dict (lambda (obj) (decrypt obj data-key)))))
                                               (invoke-pipeline
                                                 '((#$(file-append (specification->package "shadow") "/sbin/chpasswd")
                                                    "--encrypted"))
                                                 ;; guix shell --pure whois -- mkpasswd --method=SHA-256 --stdin <<< testme
                                                 #:input-strings
                                                 (map (match-lambda
                                                        (`(,user . ,passwd)
                                                         (string-append user ":" passwd "\n")))
                                                      (assoc-ref dict "passwd")))
                                               (map (lambda (file-spec)
                                                      ;; TODO: immutable flag?
                                                      (let* ((file               (assoc-ref file-spec "path"))
                                                             ; (tempfile           (string-append file ".temp"))
                                                             ; (file-store-path    (string-append "/run/sops-guix" file))
                                                             (file-umask         (assoc-ref file-spec "umask"))
                                                             (file-content       (assoc-ref file-spec "content"))
                                                             ; (file-extra-options (assoc-ref file-spec "extra-options"))
                                                             )
                                                        (mkdir-p (dirname file))
                                                        (let ((og-umask (umask)))
                                                          (when file-umask
                                                            (umask (string->number file-umask)))
                                                          (let ((output (open-file file "a")))
                                                            (display file-content output)
                                                            (close-port output))
                                                          (umask og-umask))))
                                                    (vector->list (assoc-ref dict "files")))))))))))
                       #:log-file "/var/log/sops-guix.scm")))))
      (simple-service 'erase-darling-activation activation-service-type
                      ;; TODO: This be template
                      ;; TODO: Maybe make this a new service type?
                      (with-imported-modules (source-module-closure
                                              '((guix build utils)))
                        #~(begin
                            (use-modules (ice-9 match)
                                         (ice-9 popen)
                                         (ice-9 rdelim)
                                         (guix build utils))
                            (map (lambda (lst)
                                   (apply (lambda* (dest src #:optional mode user group)
                                            (let ((users '#$(map (lambda (u) (cons (user-account-name u) (user-account-uid u)))
                                                                 (operating-system-users %bare-system)))
                                                  (groups '#$(map (lambda (g) (cons (user-group-name g) (user-group-id g)))
                                                                  (operating-system-groups %bare-system)))
                                                  (get-id (lambda (name file)
                                                            (let* ((port (open-pipe* OPEN_READ #$(file-append gawk "/bin/gawk")
                                                                                     "-F:" "$1 == NAME {print $3}" (string-append "NAME=" name)
                                                                                     file))
                                                                   (str (read-line port)))
                                                              (close-pipe port)
                                                              (string->number str)))))
                                              (unless (or (not user) (number? user))
                                                (set! user (or (assoc-ref users user)
                                                               (get-id user "/etc/passwd"))))
                                              (unless (or (not group) (number? group))
                                                (set! group (or (assoc-ref groups group)
                                                                (get-id group "/etc/group")))))

                                            ;; src->dest = persist->root-fs, like a symlink:
                                            (mkdir-p (dirname dest))
                                            (let ((perms-target (if src src dest))
                                                  (tempfile (string-append dest ".tmp")))
                                              (if (string-suffix? "/" perms-target)
                                                  (mkdir-p perms-target)
                                                  (mkdir-p (dirname perms-target)))
                                              (when (and src (file-exists? dest))
                                                (unless (file-exists? src)
                                                  (copy-recursively dest src
                                                                    #:keep-permissions? #t))
                                                (delete-file-recursively dest))
                                              (when src
                                                (when (file-exists? tempfile)
                                                  (delete-file tempfile))
                                                (symlink src tempfile)
                                                (rename-file tempfile dest))
                                              (when (file-exists? perms-target)
                                                (chown perms-target (or user -1) (or group -1))
                                                (when mode (chmod perms-target mode)))))
                                          lst))
                              ;; Fresh parent directories and omitted modes default to '#o755 root:root'.
                              '(
                                ("/etc/NetworkManager/system-connections" "/persist/etc/NetworkManager/system-connections/")
                                ("/etc/machine-id"                        "/persist/etc/machine-id"                      #o644)
                                ("/etc/ssh"                               "/persist/etc/ssh/")
                                ("/home/antlers/"                         #f                                             #o755 "antlers" "users")
                                ("/home/antlers/.cache"                   "/persist/cache/home/antlers/.cache/"          #o755 "antlers" "users")
                                ("/root/.cache"                           "/persist/cache/root/.cache/"                  #o700)
                                ("/var/cache"                             "/persist/cache/var/cache/")
                                ("/var/tmp/"                              #f)
                                ("/var/guix/substitute/cache"             "/persist/cache/var/guix/substitute/cache/")
                                ("/var/lib/fail2ban"                      "/persist/var/lib/fail2ban/"                   #o700)
                                ))
                            ; (chown "/srv/samba/guest"
                            ;        (passwd:uid (getpw "nobody"))
                            ;        (passwd:gid (getpw "nobody")))
                            ))))))))

(define %system
  ((compose os-with-zfs)
   %system))

%system
