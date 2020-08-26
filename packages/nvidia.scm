(define-module (packages nvidia)
  #:use-module (nongnu packages linux)
  #:use-module (gnu packages)
  #:use-module (gnu packages base)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages xorg)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages python)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages bootstrap)
  #:use-module (guix build-system linux-module)
  #:use-module (guix packages)
  #:use-module (guix download))

(define-public nvidia-driver
  (package
   (name "nvidia-driver")
   (version "450.66")
   (source
    (origin
     (uri
      (format #f "http://us.download.nvidia.com/XFree86/Linux-x86_64/~a/~a.run"
              version
              (format #f "NVIDIA-Linux-x86_64-~a" version)))
     (sha256 (base32 "1a6va0gvbzpkyza693v2ml1is4xbv8wxasqk0zd5y7rxin94c1ms"))
     (method url-fetch)
     (file-name (string-append "nvidia-driver-" version "-checkout"))))
   (build-system linux-module-build-system)
   (arguments
    `(#:linux ,linux
      #:phases
      (modify-phases
       %standard-phases
       (replace 'unpack
                (lambda* (#:key inputs #:allow-other-keys #:rest r)
                  (let ((source (assoc-ref inputs "source")))
                    (invoke "sh" source "--extract-only")
                    (display ,(format #f "NVIDIA-Linux-x86_64-~a" version))
                    ;; This dir name is fixed
                    (chdir ,(format #f "NVIDIA-Linux-x86_64-~a" version))
                    (invoke "pwd")
                    #t)))
       (replace 'build
                (lambda*  (#:key inputs outputs #:allow-other-keys)
                  ;; I cannot use with-directory-excursion, because the install
                  ;; phase needs to be in the kernel folder. Otherwise no .ko
                  ;; would be installed
                  (chdir "kernel")
                  ;; patch Kbuild
                  (substitute* "Kbuild"
                               (("/bin/sh") (string-append (assoc-ref inputs "bash-minimal") "/bin/sh")))
                  (invoke "make"
                          "-j"
                          (string-append "SYSSRC="
                                         (assoc-ref inputs "linux-module-builder")
                                         "/lib/modules/build")
                          "CC=gcc")
                  #t))
       (delete 'check)
       (add-after 'install 'install-copy
                  (lambda* (#:key inputs native-inputs outputs #:allow-other-keys)
                    (chdir "..")
                    ;; for scandir
                    (use-modules (ice-9 ftw)
                                 (ice-9 regex))
                    (let* ((out (assoc-ref outputs "out"))
                           (libdir (string-append out "/lib"))
                           (bindir (string-append out "/bin")))
                      ;; ------------------------------
                      ;; Copy .so files
                      (for-each
                       (lambda (file)
                         (format #t "Copying '~a'...~%" file)
                         (install-file file libdir))
                       (scandir "." (lambda (name)
                                      (string-contains name ".so"))))

                      ;; xorg files
                      (install-file "nvidia_drv.so" (string-append out "/lib/xorg/modules/drivers/"))
                      (install-file ,(string-append "libglxserver_nvidia.so." version) (string-append out "/lib/xorg/modules/extensions/"))

                      ;; ------------------------------
                      ;; Binary files
                      (install-file "nvidia-smi" bindir)

                      ;; the runpath does not seem to work, thus the nvidia-xmi
                      ;; (which is not patchelf-ed) intends to use system ld
                      ;; (with LD_LIBRARY_PATH), and seems to work
                      (copy-file "nvidia-smi" (string-append bindir "/nvidia-xmi"))

                      ;; nvidia-settings cannot pass validate_runpath with weird errors
                      ;(install-file "nvidia-settings" bindir)

                      ;; Complains that it doesn't have GLIBC_2.2.5
                      (install-file "nvidia-xconfig" bindir)

                      ;; Both of these work great!
                      (install-file "nvidia-modprobe" bindir)
                      (install-file "nvidia-debugdump" bindir)

                      ;; ------------------------------
                      ;; patchelf
                      (let* ((libc (assoc-ref inputs "libc"))
                             (ld.so (string-append libc ,(glibc-dynamic-linker)))
                             (out (assoc-ref outputs "out"))
                             (rpath (string-join
                                     (list "$ORIGIN"
                                           (string-append out "/lib")
                                           (string-append libc "/lib")
                                           (string-append (assoc-ref inputs "libx11") "/lib")
                                           (string-append (assoc-ref inputs "libxext") "/lib")
                                           (string-append (assoc-ref inputs "pango") "/lib")
                                           (string-append (assoc-ref inputs "gtk+") "/lib")
                                           (string-append (assoc-ref inputs "gtk2") "/lib")
                                           (string-append (assoc-ref inputs "atk") "/lib")
                                           (string-append (assoc-ref inputs "glib") "/lib")
                                           (string-append (assoc-ref inputs "cairo") "/lib")
                                           (string-append (assoc-ref inputs "gdk-pixbuf") "/lib")
                                           (string-append (assoc-ref inputs "wayland") "/lib")
                                           (string-append (assoc-ref inputs "gcc:lib") "/lib"))
                                     ":")))
                        (define (patch-elf file)
                          (format #t "Patching ~a ...~%" file)
                          (unless (string-contains file ".so")
                            (invoke "patchelf" "--set-interpreter" ld.so file))
                          (invoke "patchelf" "--set-rpath" rpath file))
                        (for-each (lambda (file)
                                    (when (elf-file? file)
                                      (patch-elf file)))
                                  (find-files out  ".*\\.so"))
                        ;; patch nvidia-smi but leave nvidia-xmi untouched
                        (patch-elf (string-append out "/bin/nvidia-smi"))

                        (patch-elf (string-append out "/bin/nvidia-xconfig"))
                        (patch-elf (string-append out "/bin/nvidia-modprobe"))
                        (patch-elf (string-append out "/bin/nvidia-debugdump")))
                      ;; ------------------------------
                      ;; Create short name symbolic links
                      (for-each (lambda (file)
                                  (let* ((short (regexp-substitute
                                                 #f
                                                 (string-match "([^/]*\\.so).*" file)
                                                 1))
                                         (major (if (or (string=? short "libEGL.so")
                                                        (string=? short "libEGL_nvidia.so")
                                                        (string=? short "libGLX.so")
                                                        (string=? short "libGLX_nvidia.so"))
                                                    "0" "1"))
                                         (mid (string-append short "." major))
                                         (short-file (string-append libdir "/" short))
                                         (mid-file (string-append libdir "/" mid)))
                                    ;; FIXME the same name, print out warning at least
                                    ;; [X] libEGL.so.1.1.0
                                    ;; [ ] libEGL.so.VERSION
                                    (when (not (file-exists? short-file))
                                      (format #t "Linking ~a to ~a ...~%" short file)
                                      (symlink (basename file) short-file))
                                    (when (not (file-exists? mid-file))
                                      (format #t "Linking ~a to ~a ...~%" mid file)
                                      (symlink (basename file) mid-file))))
                                (find-files libdir "\\.so\\."))
                      (symlink ,(string-append "libglxserver_nvidia.so." version)
                               (string-append out "/lib/xorg/modules/extensions/" "libglxserver_nvidia.so")))
                    #t)))))
   (native-inputs
    `(("patchelf" ,patchelf)
      ("perl" ,perl)
      ("python" ,python-2)
      ("xz" ,xz)
      ("which" ,which)))
   (inputs
    `(("gcc:lib" ,gcc "lib")
      ("libc" ,glibc)
      ("libx11" ,libx11)
      ("libxext" ,libxext)
      ("pango" ,pango)
      ("gtk+" ,gtk+)
      ("gdk-pixbuf" ,gdk-pixbuf)
      ("gtk2" ,gtk+-2)
      ("cairo" ,cairo)
      ("kmod" ,kmod)
      ("wayland" ,wayland)
      ("atk" ,atk)
      ("glib" ,glib)
      ("bash-minimal" ,bash-minimal)))
   (home-page "https://www.nvidia.com")
   (synopsis "Proprietary Nvidia Driver")
   (description "Evil driver")
   (license #f)))
