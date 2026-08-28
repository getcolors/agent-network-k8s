(ns io.github.getcolors.agent-network-k8s.utils
  (:require [clojure.string :as str]))

(def contract 1)

(defn registrable-domain
  "The registrable (zone) domain of a hostname: its last two labels. Good
  enough for the zones this package serves; a public-suffix list would be a
  dependency for a case no deployment has."
  [host]
  (let [labels (str/split (str host) #"\.")]
    (str/join "." (take-last 2 labels))))

(defn registry-name
  "What this deployment calls its container registry. Vultr registry names
  accept lowercase alphanumerics only, so the profile-derived name (Compute
  Name Standard) is the profile with every other character removed."
  [profile]
  (str/replace (str/lower-case (str profile)) #"[^a-z0-9]" ""))
