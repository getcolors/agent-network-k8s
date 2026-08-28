(ns io.github.getcolors.agent-network-k8s.tools-test
  (:require [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [green.cli :as green-cli]
            [green.scaffold :as sc]
            [io.github.getcolors.agent-network-k8s.tools :as tools]))

(defn fixture []
  (assoc (green-cli/read-state "test/fixtures/colors.yml" (slurp "test/fixtures/colors.yml"))
         :green/state-file "test/fixtures/colors.yml"))

(deftest dns-records
  (let [doc (json/parse-string (tools/dns-json (assoc (fixture) :lb-ip "203.0.113.9")))]
    (testing "base and wildcard, both unproxied, both at the LB"
      (let [records (get-in doc ["resource" "cloudflare_dns_record"])
            base (get records "agent_network_k8s")
            wild (get records "agent_network_k8s_wildcard")]
        (is (= "agent-network-k8s.example.com" (get base "name")))
        (is (= "*.agent-network-k8s.example.com" (get wild "name")))
        (is (= "203.0.113.9" (get base "content") (get wild "content")))
        (is (= false (get base "proxied") (get wild "proxied")))))))

(deftest desired-document
  (let [doc (json/parse-string (tools/desired-json (fixture)))]
    (testing "the catalog provider id, not the bare name (422 otherwise)"
      (is (= "anthropic_api" (get-in doc ["provider" "provider_id"]))))
    (testing "two claimed models, one allowed — both denial classes derivable"
      (is (= 2 (count (get-in doc ["provider" "models"]))))
      (is (= ["claude-haiku-4-5-20251001"] (get doc "allowed_models"))))
    (testing "caps and retention travel"
      (is (= 2 (get-in doc ["policy" "budget_usd_per_day"])))
      (is (= 5000000 (get-in doc ["global" "tokens_per_day"])))
      (is (= 7 (get doc "log_retention_days"))))
    (testing "no secret has any business here"
      (is (not (str/includes? (tools/desired-json (fixture)) "api_key"))))))

(deftest deploy-rendering
  (let [opts (assoc (fixture) :workdir (str (System/getProperty "java.io.tmpdir")
                                            "/an-k8s-test-" (System/nanoTime)))
        specs (tools/deploy-specs opts)
        rendered (sc/scaffold (assoc opts :green/event :create) specs)
        written (:green.scaffold/written rendered)
        slurp-target (fn [suffix]
                       (slurp (first (filter #(str/ends-with? % suffix) written))))]
    (testing "every deploy file renders"
      (is (= (+ 2 (count tools/deploy-files)) (count written))))
    (testing "the host reaches the scripts and manifests"
      (is (str/includes? (slurp-target "bootstrap.sh") "agent-network-k8s.example.com"))
      (is (str/includes? (slurp-target "manifests/proxy.yaml")
                         "NB_PROXY_DOMAIN"))
      (is (str/includes? (slurp-target "traefik-dynamic.yaml")
                         "HostSNIRegexp")))
    (testing "the passthrough matches subdomains only, never the bare base name"
      (let [dyn (slurp-target "traefik-dynamic.yaml")]
        (is (str/includes? dyn "HostSNIRegexp(`^[a-z0-9-]+\\.agent-network-k8s\\.example\\.com$`)"))
        ;; No router may carry the catch-all rule (the comment may name it).
        (is (not (re-find #"rule:.*HostSNI\(`\*`\)" dyn)))))
    (testing "every model knob is pinned in both agent variants"
      (doseq [variant ["manifests/agent-primary.yaml" "manifests/agent-fallback.yaml"]
              knob ["ANTHROPIC_MODEL" "ANTHROPIC_SMALL_FAST_MODEL"
                    "ANTHROPIC_DEFAULT_OPUS_MODEL" "ANTHROPIC_DEFAULT_SONNET_MODEL"
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL"]]
        (let [content (slurp-target variant)]
          (is (str/includes? content knob) (str variant " " knob))
          (is (str/includes? content "claude-haiku-4-5-20251001") variant))))
    (testing "the agent pod mounts no ServiceAccount token and no DNS path"
      (let [agent (slurp-target "manifests/agent-primary.yaml")]
        (is (str/includes? agent "automountServiceAccountToken: false"))))
    (testing "the client entry is state-aware: reconnect without a key"
      (let [entry (slurp-target "socks-entry.sh")]
        (is (str/includes? entry "reconnecting without a key"))
        (is (str/includes? entry "--setup-key-file"))))
    (testing "the one-off key never becomes a Kubernetes Secret"
      (let [bootstrap (slurp-target "bootstrap.sh")]
        (is (str/includes? bootstrap "/dev/shm"))
        (is (not (re-find #"create secret.*setup" bootstrap)))))))

(deftest per-profile-paths
  (let [opts (fixture)]
    (is (str/ends-with? (tools/kubeconfig-path opts)
                        "agent-network-k8s-fixture/kubeconfig"))
    (is (str/ends-with? (tools/state-dir opts)
                        "agent-network-k8s-fixture/state"))))

(deftest cidr-splitting
  (is (= ["1.2.3.0/24" "5.6.7.0/24"]
         (tools/cidrs {:vultr-http-sources ["1.2.3.0/24" "5.6.7.0/24"]} :vultr-http-sources)))
  (is (= ["1.2.3.0/24"]
         (tools/cidrs {:vultr-http-sources "1.2.3.0/24"} :vultr-http-sources))))
