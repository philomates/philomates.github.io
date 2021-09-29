(ns cryogen.server
  (:require 
   [clojure.string :as string]
   [compojure.core :refer [GET defroutes]]
   [compojure.route :as route]
   [ring.util.response :refer [redirect file-response]]
   [ring.util.codec :refer [url-decode]]
   [ring.server.standalone :as ring-server]
   [cryogen-core.watcher :refer [start-watcher! start-watcher-for-changes!]]
   [cryogen-core.plugins :refer [load-plugins]]
   [cryogen-core.compiler :refer [compile-assets-timed group-for-archive]]
   [cryogen-core.config :refer [resolve-config]]
   [cryogen-core.io :refer [copy-resources path]]))

(defn group-for-archive-with-desc
  "Groups the posts by month and year for archive sorting"
  [posts]
  (println "custom")
  (->> posts
       (map #(select-keys % [:title :uri :date :formatted-archive-group :parsed-archive-group :description]))
       (group-by :formatted-archive-group)
       (map (fn [[group posts]]
              {:group        group
               :parsed-group (:parsed-archive-group (get posts 0))
               :posts        (map #(let [x (select-keys % [:title :uri :date :description])]
                                     (clojure.pprint/pprint x)
                                     x)
                                  posts)}))
       (sort-by :parsed-group)
       reverse))

(defn custom-compile-assets-timed []
  (with-redefs [group-for-archive group-for-archive-with-desc]
    (compile-assets-timed))
  (copy-resources "content" (resolve-config)))

(defn init [fast?]
  (println "Init: fast compile enabled = " (boolean fast?))
  (load-plugins)
  (custom-compile-assets-timed)
  (let [ignored-files (-> (resolve-config) :ignored-files)]
    (run!
      #(if fast?
         (start-watcher-for-changes! % ignored-files custom-compile-assets-timed {})
         (start-watcher! % ignored-files custom-compile-assets-timed))
      ["content" "themes"])))

(defn wrap-subdirectories
  [handler]
  (fn [request]
    (let [{:keys [clean-urls blog-prefix public-dest]} (resolve-config)
          req-uri (.substring (url-decode (:uri request)) 1)
          res-path (if (or (.endsWith req-uri "/")
                           (.endsWith req-uri ".html")
                           (-> (string/split req-uri #"/")
                               last
                               (string/includes? ".")
                               not))
                     (condp = clean-urls
                       :trailing-slash (path req-uri "index.html")
                       :no-trailing-slash (if (or (= req-uri "")
                                                  (= req-uri "/")
                                                  (= req-uri
                                                     (if (string/blank? blog-prefix)
                                                       blog-prefix
                                                       (.substring blog-prefix 1))))
                                            (path req-uri "index.html")
                                            (path (str req-uri ".html")))
                       :dirty (path (str req-uri ".html")))
                     req-uri)]
      (or (file-response res-path {:root public-dest})
          (handler request)))))

(defroutes routes
  (GET "/" [] (redirect (let [config (resolve-config)]
                          (path (:blog-prefix config)
                                (when (= (:clean-urls config) :dirty)
                                  "index.html")))))
  (route/files "/")
  (route/not-found "Page not found"))

(def handler (wrap-subdirectories routes))

(defn serve
  "Entrypoint for running via tools-deps (clojure)"
  [{:keys [fast] :as opts}]
  (ring-server/serve
    handler
    (merge {:init (partial init fast)} opts)))

(defn -main [& args]
  (serve {:port 3000, :fast ((set args) "fast")}))
