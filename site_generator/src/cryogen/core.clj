(ns cryogen.core
  (:require [cryogen.server :refer [custom-compile-assets-timed]]
            [cryogen-core.plugins :refer [load-plugins]]))

(defn -main []
  (load-plugins)
  (custom-compile-assets-timed)
  (System/exit 0))
