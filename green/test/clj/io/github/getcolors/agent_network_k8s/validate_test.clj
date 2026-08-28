(ns io.github.getcolors.agent-network-k8s.validate-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [green.cli :as green-cli]
            [io.github.getcolors.agent-network-k8s.validate :as validate]))

(defn fixture []
  (green-cli/read-state "test/fixtures/colors.yml" (slurp "test/fixtures/colors.yml")))

(deftest fixture-is-valid
  (is (= [] (validate/state-errors (fixture)))))

(deftest required-keys-are-enforced
  (doseq [k validate/required]
    (let [errors (validate/state-errors (dissoc (fixture) k))]
      (is (some #(str/includes? % (str k)) errors)
          (str k " missing must be reported")))))

(deftest env-guard
  (is (nil? (validate/env-errors {})))
  (is (seq (validate/env-errors {"COLORS_PAR_PROFILE" "other"}))))

(deftest image-pins
  (testing "a floating tag is refused"
    (doseq [bad ["netbirdio/netbird:latest" "netbirdio/netbird:main"
                 "netbirdio/netbird:latest@sha256:66f408b0c423e9c3376deea7bc0da78024d32494dd0f957344993015b74c4451"]]
      (is (seq (validate/state-errors (assoc (fixture) :agent-network-client-image bad)))
          bad)))
  (testing "a bare repository means :latest by implication and is refused"
    (is (seq (validate/state-errors (assoc (fixture) :agent-network-client-image "netbirdio/netbird"))))))

(deftest model-shape
  (testing "the allowlist must be claimed"
    (is (seq (validate/model-errors
              (assoc (fixture) :agent-network-allowed-models ["not-claimed"])))))
  (testing "at least one claimed model must sit outside the allowlist"
    (is (seq (validate/model-errors
              (assoc (fixture)
                     :agent-network-allowed-models
                     ["claude-haiku-4-5-20251001" "claude-sonnet-4-5-20250929"])))))
  (testing "the denial probe's negative case is derivable"
    (is (= "claude-sonnet-4-5-20250929" (validate/denied-claimed-model (fixture))))
    (is (= "claude-haiku-4-5-20251001" (validate/allowed-model (fixture))))))

(deftest budget-ceilings
  (is (seq (validate/state-errors
            (assoc (fixture) :agent-network-policy-budget-usd-per-day 50))))
  (is (seq (validate/state-errors
            (assoc (fixture) :agent-network-policy-tokens-per-day 99999999)))))

(deftest vke-version-shape
  (is (= [] (validate/state-errors (assoc (fixture) :vultr-vke-version "v1.34.0+3"))))
  (doseq [bad ["1.35.2+1" "v1.35.2" "v1.35+1" "latest"]]
    (is (seq (validate/state-errors (assoc (fixture) :vultr-vke-version bad))) bad)))

(deftest naming
  (testing "the compute name defaults to the profile (Compute Name Standard)"
    (is (= "agent-network-k8s-fixture" (validate/compute-name (fixture))))
    (is (= "custom" (validate/compute-name (assoc (fixture) :vultr-name "custom"))))
    (is (= "agent-network-k8s-fixture"
           (validate/compute-name (assoc (fixture) :vultr-name "REPLACE_ME")))))
  (testing "the registry name is the compute name reduced to what Vultr accepts"
    (is (= "agentnetworkk8sfixture" (validate/registry-name (fixture))))))

(deftest zone-derivation
  (is (= "example.com" (validate/zone (fixture)))))

(deftest secret-requirements
  (testing "create needs the providers, the backend and the Anthropic key"
    (let [errors (validate/secret-errors (assoc (fixture) :provider-backend "r2") :create)]
      (doseq [v ["COLORS_PAR_VULTR_API_KEY" "COLORS_PAR_CLOUDFLARE_API_TOKEN"
                 "COLORS_PAR_ANTHROPIC_API_KEY" "COLORS_PAR_R2_ACCESS_KEY_ID"]]
        (is (some #(str/includes? % v) errors) v))))
  (testing "delete never demands the Anthropic key"
    (let [errors (validate/secret-errors (fixture) :delete)]
      (is (not-any? #(str/includes? % "ANTHROPIC") errors)))))

(deftest gost-pin-shape
  (is (seq (validate/state-errors (assoc (fixture) :agent-network-gost-sha256 "abc"))))
  (is (seq (validate/state-errors (assoc (fixture) :agent-network-gost-version "3.2")))))
