(ns pin (:require [clojure.java.shell :as sh] [clojure.string :as str]))
;; One SHA, one payload. The payload is born unpinned — no invented SHAs —
;; and `bb pin` stamps or re-stamps it after a clean, pushed HEAD. The site
;; recognises exactly two forms, its unpinned birth shape and its pinned
;; shape, and the run fails loudly when it matches neither.
(defn git [& args] (let [{:keys [exit out]} (apply sh/sh "git" args)] (when (zero? exit) (str/trim out))))

(defn stamp-green [s sha]
  (when (re-find #"\(def \^:private agent-network-k8s-sha (?:nil|\"[0-9a-f]{40}\")\)" s)
    (str/replace-first s #"\(def \^:private agent-network-k8s-sha (?:nil|\"[0-9a-f]{40}\")\)"
                       (str "(def ^:private agent-network-k8s-sha \"" sha "\")"))))

(def sites
  [{:path "../skills/package-agent-network-k8s-green/green" :stamp stamp-green}])

(let [dirty (git "status" "--porcelain") sha (git "rev-parse" "HEAD") remotes (git "branch" "-r" "--contains" sha)]
  (cond (seq dirty) (do (binding [*out* *err*] (println "agent-network-k8s working tree is dirty; commit before pinning")) (System/exit 2))
        (not (str/includes? (str remotes) "origin/")) (do (binding [*out* *err*] (println "agent-network-k8s HEAD is not pushed")) (System/exit 2))
        :else (let [errors (atom [])]
                (doseq [{:keys [path stamp]} sites]
                  (let [s (slurp path) n (stamp s sha)]
                    (if n (spit path n) (swap! errors conj (str "could not locate a pin form in " path)))))
                (if (seq @errors)
                  (do (binding [*out* *err*] (println (str/join "\n" @errors))) (System/exit 2))
                  (println "pinned 1 launcher to" (subs sha 0 7))))))
