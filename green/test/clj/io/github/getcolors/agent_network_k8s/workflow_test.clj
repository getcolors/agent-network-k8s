(ns io.github.getcolors.agent-network-k8s.workflow-test
  (:require [clojure.string :as str]
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
    (is (= [:agent-network-k8s/infrastructure :agent-network-k8s/deploy
            :agent-network-k8s/dns :agent-network-k8s/certificate
            :agent-network-k8s/bootstrap :agent-network-k8s/agent
            :agent-network-k8s/acceptance]
           (chain :create)))))

(deftest delete-ordering
  (testing "in-cluster teardown precedes the infrastructure destroy; local
            access material goes last"
    (is (= [:agent-network-k8s/teardown :agent-network-k8s/dns
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
      (is (str/includes? (str (:green/err out)) ":vultr-vke-version"))))
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
