(ns io.github.getcolors.agent-network-k8s.workflow-test
  (:require [io.github.getcolors.agent-network-k8s.tools :as tools] [green.workflow :as wf] [clojure.java.io :as io] [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [green.cli :as green-cli]
            [io.github.getcolors.agent-network-k8s.workflow :as workflow]))

(defn fixture []
  (green-cli/read-state "test/fixtures/colors.yml" (slurp "test/fixtures/colors.yml")))

(defn chain [event]
  (loop [step :agent-network-k8s/start acc []]
    (let [[_ next-step] (workflow/wire-fn step {:green/event event})]
      (if next-step
        (recur next-step (conj acc next-step))
        acc))))

(deftest create-ordering
  (testing "cluster → workloads → dns → certificate → bootstrap → agent → gates"
    (is (= [:agent-network-k8s/infrastructure :agent-network-k8s/registry :agent-network-k8s/deploy
            :agent-network-k8s/dns :agent-network-k8s/certificate
            :agent-network-k8s/bootstrap :agent-network-k8s/agent
            :agent-network-k8s/acceptance]
           (chain :create)))))

(deftest delete-ordering
  (testing "in-cluster teardown precedes the infrastructure destroy; local
            access material goes last"
    (is (= [:agent-network-k8s/load-infrastructure :agent-network-k8s/teardown :agent-network-k8s/dns :agent-network-k8s/registry
            :agent-network-k8s/infrastructure :agent-network-k8s/cleanup]
           (chain :delete)))))

(deftest every-side-effecting-step-is-dry-runnable
  (let [wired (distinct (concat (chain :create) (chain :delete)))]
    (doseq [step wired]
      (is (some #{step} workflow/side-effecting) (str step)))))

(deftest start-validates
  (testing "a valid fixture passes"
    (let [out (workflow/start-step (assoc (fixture) :green/event :build) {})]
      (is (zero? (:green/exit out)))))
  (testing "missing desired state aggregates every error at exit 2"
    (let [out (workflow/start-step (-> (fixture)
                                       (dissoc :agent-network-host :vultr-vke-version)
                                       (assoc :green/event :build))
                                   {})]
      (is (= 2 (:green/exit out)))
      (is (str/includes? (str (:green/err out)) ":agent-network-host"))
      (is (str/includes? (str (:green/err out)) "missing managed Kubernetes settings"))))
  (testing "the profile guard refuses the overlay"
    (let [out (workflow/start-step (assoc (fixture) :green/event :build)
                                   {"COLORS_PAR_PROFILE" "other"})]
      (is (= 2 (:green/exit out)))))
  (testing "a real delete is refused while the guard stands"
    (let [out (workflow/start-step (assoc (fixture)
                                          :green/event :delete
                                          :vultr-api-key "x"
                                          :cloudflare-api-token "x")
                                   {})]
      (is (= 2 (:green/exit out)))
      (is (str/includes? (str (:green/err out)) "COLORS_PAR_COMPUTE_PREVENT_DESTROY")))))

(deftest retired-resumes-only-idempotent-local-cleanup
  (let [dir (.toFile (java.nio.file.Files/createTempDirectory "agent-network-k8s-retired-" (make-array java.nio.file.attribute.FileAttribute 0)))
        opts {:profile "retired" :workdir (str dir) :green/event :delete}
        paths [(io/file (tools/kubeconfig-path opts)) (io/file (tools/state-dir opts) "leftover") (io/file (tools/profile-dir opts) "proofs/leftover")]
        keep (io/file dir "keep") seen (atom []) inspection-exit (atom 0)
        native (wf/workflow {:start :agent-network-k8s/start :next-fn workflow/next-steps
          :wire-fn (fn [step current]
            (case step
              :agent-network-k8s/start [(fn [o] (swap! seen conj step) (assoc o :green/exit 0)) :agent-network-k8s/load-managed]
              :agent-network-k8s/load-managed [(fn [o] (swap! seen conj step) (assoc o :green/exit @inspection-exit :agent-network-k8s/already-destroyed true)) :forbidden/remote]
              :agent-network-k8s/cleanup [(fn [o] (swap! seen conj step) ((first (workflow/wire-fn step o)) o))]
              [(fn [_] (throw (ex-info "unexpected remote stage" {:step step})))]))})]
    (try
      (doseq [path paths] (io/make-parents path) (spit path "synthetic leftover"))
      (spit keep "unrelated")
      (dotimes [_ 2]
        (reset! seen [])
        (is (zero? (:green/exit (wf/run native opts))))
        (is (= [:agent-network-k8s/start :agent-network-k8s/load-managed :agent-network-k8s/cleanup] @seen))
        (is (every? #(not (.exists %)) paths))
        (is (= "unrelated" (slurp keep))))
      (reset! inspection-exit 1) (reset! seen [])
      (is (= 1 (:green/exit (wf/run native opts))))
      (is (= [:agent-network-k8s/start :agent-network-k8s/load-managed] @seen))
      (is (= [] (workflow/next-steps :agent-network-k8s/load-managed [:forbidden/remote] (assoc opts :green/exit 1 :agent-network-k8s/already-destroyed true))))
      (is (not (.exists (io/file dir ".ssh"))))
      (finally (doseq [f (reverse (file-seq dir))] (io/delete-file f true))))))
