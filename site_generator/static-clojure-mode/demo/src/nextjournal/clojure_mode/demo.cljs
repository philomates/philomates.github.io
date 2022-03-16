(ns nextjournal.clojure-mode.demo
  (:require ["@codemirror/gutter" :refer [lineNumbers]]
            ["@codemirror/highlight" :as highlight]
            ["@codemirror/state" :refer [EditorState]]
            ["@codemirror/view" :refer [EditorView]]
            [applied-science.js-interop :as j]
            [nextjournal.clojure-mode :as cm-clj]
            [reagent.dom :as rdom]))

(defonce extensions #js[highlight/defaultHighlightStyle
                        (lineNumbers)
                        (.. EditorView -editable (of false))
                        cm-clj/default-extensions])

(defn editor [source]
  [:div
   [:div {:class "rounded-md mb-0 text-sm monospace overflow-auto relative border shadow-lg bg-white"
          :ref (fn [el]
                 (let [prev-view (j/get el :editorView)]
                   (when (or (nil? prev-view)
                             (not= source (j/call-in prev-view [:state :doc :toString])))
                     (some-> prev-view (j/call :destroy))
                     (j/assoc! el :editorView (new EditorView
                                                   (j/obj :state
                                                          (.create EditorState #js {:doc source :extensions extensions})
                                                          :parent el))))))}]])

(defn ^:export render [tag source]
  (rdom/render (editor source) (js/document.getElementById tag)))
