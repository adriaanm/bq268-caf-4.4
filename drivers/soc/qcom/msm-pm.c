/*
 * MSM Power Management — non-PSCI idle/sleep for ARMv7 Qualcomm SoCs.
 *
 * Ported from msm-3.18 drivers/power/qcom/msm-pm.c for MSM8909 support
 * in the CAF 4.4 kernel (which only had PSCI paths).
 *
 * Copyright (c) 2010-2017, The Linux Foundation. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 and
 * only version 2 as published by the Free Software Foundation.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/clk.h>
#include <linux/io.h>
#include <linux/smp.h>
#include <linux/platform_device.h>
#include <linux/of_platform.h>
#include <linux/dma-mapping.h>
#include <soc/qcom/spm.h>
#include <soc/qcom/pm.h>
#include <soc/qcom/scm.h>
#include <soc/qcom/scm-boot.h>
#include <soc/qcom/jtag.h>
#include <asm/suspend.h>
#include <asm/cacheflush.h>
#include <asm/cputype.h>
#include <asm/smp_plat.h>
#ifdef CONFIG_VFP
#include <asm/vfp.h>
#endif
#include "idle.h"
#include "pm-boot.h"

#define SCM_CMD_TERMINATE_PC	(0x2)
#define SCM_CMD_CORE_HOTPLUGGED (0x10)
#define SCM_FLUSH_FLAG_MASK	(0x3)

static bool msm_pm_tz_flushes_cache;
static bool msm_pm_ret_no_pll_switch;
static bool msm_no_ramp_down_pc;
static bool msm_pm_ldo_retention_enabled = true;

DEFINE_PER_CPU(struct clk *, cpu_clks);
static struct clk *l2_clk;
static long *msm_pc_debug_counters;

static cpumask_t retention_cpus;
static DEFINE_SPINLOCK(retention_lock);

enum msm_pc_count_offsets {
	MSM_PC_ENTRY_COUNTER,
	MSM_PC_EXIT_COUNTER,
	MSM_PC_FALLTHRU_COUNTER,
	MSM_PC_UNUSED,
	MSM_PC_NUM_COUNTERS,
};

static bool msm_pm_is_L1_writeback(void)
{
	u32 cache_id = 0;
	u32 sel = 0;

	asm volatile ("mcr p15, 2, %[ccselr], c0, c0, 0\n\t"
		      "isb\n\t"
		      "mrc p15, 1, %[ccsidr], c0, c0, 0\n\t"
		      :[ccsidr]"=r" (cache_id)
		      :[ccselr]"r" (sel)
		     );
	return cache_id & BIT(30);
}

static inline void msm_pc_inc_debug_count(uint32_t cpu,
		enum msm_pc_count_offsets offset)
{
	int cntr_offset;
	uint32_t cluster_id = MPIDR_AFFINITY_LEVEL(cpu_logical_map(cpu), 1);
	uint32_t cpu_id = MPIDR_AFFINITY_LEVEL(cpu_logical_map(cpu), 0);

	if (cluster_id >= MAX_NUM_CLUSTER || cpu_id >= MAX_CPUS_PER_CLUSTER)
		return;

	cntr_offset = (cluster_id * MAX_CPUS_PER_CLUSTER * MSM_PC_NUM_COUNTERS)
			 + (cpu_id * MSM_PC_NUM_COUNTERS) + offset;

	if (!msm_pc_debug_counters)
		return;

	msm_pc_debug_counters[cntr_offset]++;
}

static bool msm_pm_swfi(bool from_idle)
{
	msm_arch_idle();
	return true;
}

static bool msm_pm_retention(bool from_idle)
{
	int ret;
	unsigned int cpu = smp_processor_id();
	struct clk *cpu_clk = per_cpu(cpu_clks, cpu);

	spin_lock(&retention_lock);

	if (!msm_pm_ldo_retention_enabled)
		goto bailout;

	cpumask_set_cpu(cpu, &retention_cpus);
	spin_unlock(&retention_lock);

	if (!msm_pm_ret_no_pll_switch && cpu_clk)
		clk_disable(cpu_clk);

	ret = msm_spm_set_low_power_mode(MSM_SPM_MODE_RETENTION, false);
	WARN_ON(ret);

	msm_arch_idle();

	ret = msm_spm_set_low_power_mode(MSM_SPM_MODE_CLOCK_GATING, false);
	WARN_ON(ret);

	if (!msm_pm_ret_no_pll_switch && cpu_clk)
		if (clk_enable(cpu_clk))
			pr_err("%s(): Error restore cpu clk\n", __func__);

	spin_lock(&retention_lock);
	cpumask_clear_cpu(cpu, &retention_cpus);
bailout:
	spin_unlock(&retention_lock);
	return true;
}

static bool msm_pm_pc_hotplug(void)
{
	uint32_t cpu = smp_processor_id();
	enum msm_pm_l2_scm_flag flag;
	struct scm_desc desc;

	flag = lpm_cpu_pre_pc_cb(cpu);

	if (!msm_pm_tz_flushes_cache) {
		if (flag == MSM_SCM_L2_OFF)
			flush_cache_all();
		else if (msm_pm_is_L1_writeback())
			flush_cache_louis();
	}

	msm_pc_inc_debug_count(cpu, MSM_PC_ENTRY_COUNTER);

	if (is_scm_armv8()) {
		desc.args[0] = SCM_CMD_CORE_HOTPLUGGED |
			       (flag & SCM_FLUSH_FLAG_MASK);
		desc.arginfo = SCM_ARGS(1);
		scm_call2_atomic(SCM_SIP_FNID(SCM_SVC_BOOT,
				 SCM_CMD_TERMINATE_PC), &desc);
	} else {
		scm_call_atomic1(SCM_SVC_BOOT, SCM_CMD_TERMINATE_PC,
		SCM_CMD_CORE_HOTPLUGGED | (flag & SCM_FLUSH_FLAG_MASK));
	}

	/* Should not return here */
	msm_pc_inc_debug_count(cpu, MSM_PC_FALLTHRU_COUNTER);
	return 0;
}

int msm_pm_collapse(unsigned long unused)
{
	uint32_t cpu = smp_processor_id();
	enum msm_pm_l2_scm_flag flag;
	struct scm_desc desc;

	flag = lpm_cpu_pre_pc_cb(cpu);

	if (!msm_pm_tz_flushes_cache) {
		if (flag == MSM_SCM_L2_OFF)
			flush_cache_all();
		else if (msm_pm_is_L1_writeback())
			flush_cache_louis();
	}
	msm_pc_inc_debug_count(cpu, MSM_PC_ENTRY_COUNTER);

	if (is_scm_armv8()) {
		desc.args[0] = flag;
		desc.arginfo = SCM_ARGS(1);
		scm_call2_atomic(SCM_SIP_FNID(SCM_SVC_BOOT,
				 SCM_CMD_TERMINATE_PC), &desc);
	} else {
		scm_call_atomic1(SCM_SVC_BOOT, SCM_CMD_TERMINATE_PC, flag);
	}

	msm_pc_inc_debug_count(cpu, MSM_PC_FALLTHRU_COUNTER);

	return 0;
}
EXPORT_SYMBOL(msm_pm_collapse);

static bool __ref msm_pm_spm_power_collapse(
	unsigned int cpu, int mode, bool from_idle, bool notify_rpm)
{
	void *entry;
	bool collapsed = 0;
	int ret;
	bool save_cpu_regs = (cpu_online(cpu) || from_idle);

	ret = msm_spm_set_low_power_mode(mode, notify_rpm);
	WARN_ON(ret);

	entry = save_cpu_regs ? cpu_resume : msm_secondary_startup;

	msm_pm_boot_config_before_pc(cpu, virt_to_phys(entry));

	msm_jtag_save_state();

	collapsed = save_cpu_regs ?
		!cpu_suspend(0, msm_pm_collapse) : msm_pm_pc_hotplug();

	msm_jtag_restore_state();

	if (collapsed)
		local_fiq_enable();

	msm_pm_boot_config_after_pc(cpu);

	ret = msm_spm_set_low_power_mode(MSM_SPM_MODE_CLOCK_GATING, false);
	WARN_ON(ret);
	return collapsed;
}

static bool msm_pm_power_collapse_standalone(bool from_idle)
{
	unsigned int cpu = smp_processor_id();

	return msm_pm_spm_power_collapse(cpu,
			MSM_SPM_MODE_STANDALONE_POWER_COLLAPSE,
			from_idle, false);
}

static bool msm_pm_power_collapse(bool from_idle)
{
	unsigned int cpu = smp_processor_id();
	bool collapsed;

	/*
	 * MSM8909 has qcom,synced-clocks — no per-CPU clock ramp needed.
	 * The msm_no_ramp_down_pc flag is set when qcom,synced-clocks is
	 * in the DTS, but we also just skip unconditionally for safety.
	 */
	collapsed = msm_pm_spm_power_collapse(cpu,
			MSM_SPM_MODE_POWER_COLLAPSE, from_idle, true);

	return collapsed;
}

static bool (*execute[MSM_PM_SLEEP_MODE_NR])(bool idle) = {
	[MSM_PM_SLEEP_MODE_WAIT_FOR_INTERRUPT] = msm_pm_swfi,
	[MSM_PM_SLEEP_MODE_POWER_COLLAPSE_STANDALONE] =
		msm_pm_power_collapse_standalone,
	[MSM_PM_SLEEP_MODE_RETENTION] = msm_pm_retention,
	[MSM_PM_SLEEP_MODE_POWER_COLLAPSE] = msm_pm_power_collapse,
};

bool msm_cpu_pm_enter_sleep(enum msm_pm_sleep_mode mode, bool from_idle)
{
	bool exit_stat = false;

	if (mode < MSM_PM_SLEEP_MODE_NR && execute[mode])
		exit_stat = execute[mode](from_idle);

	return exit_stat;
}

void msm_pm_enable_retention(bool enable)
{
	if (enable == msm_pm_ldo_retention_enabled)
		return;

	msm_pm_ldo_retention_enabled = enable;

	if (!enable) {
		preempt_disable();
		smp_call_function_many(&retention_cpus,
				NULL, NULL, true);
		preempt_enable();
	}
}
EXPORT_SYMBOL(msm_pm_enable_retention);

bool msm_pm_retention_enabled(void)
{
	return msm_pm_ldo_retention_enabled;
}
EXPORT_SYMBOL(msm_pm_retention_enabled);

static int msm_pm_clk_init(struct platform_device *pdev)
{
	bool synced_clocks;
	u32 cpu;
	char clk_name[] = "cpu??_clk";
	char *key;

	key = "qcom,saw-turns-off-pll";
	if (of_property_read_bool(pdev->dev.of_node, key))
		return 0;

	key = "qcom,synced-clocks";
	synced_clocks = of_property_read_bool(pdev->dev.of_node, key);

	for_each_possible_cpu(cpu) {
		struct clk *clk;

		snprintf(clk_name, sizeof(clk_name), "cpu%d_clk", cpu);
		clk = clk_get(&pdev->dev, clk_name);
		if (IS_ERR(clk)) {
			if (cpu && synced_clocks)
				return 0;
			else
				clk = NULL;
		}
		per_cpu(cpu_clks, cpu) = clk;
	}

	if (synced_clocks) {
		msm_no_ramp_down_pc = true;
		return 0;
	}

	l2_clk = clk_get(&pdev->dev, "l2_clk");
	if (IS_ERR(l2_clk))
		pr_warn("%s: Could not get l2_clk (-%ld)\n", __func__,
			PTR_ERR(l2_clk));

	return 0;
}

static int msm_cpu_pm_probe(struct platform_device *pdev)
{
	int ret;
	int alloc_size = MAX_NUM_CLUSTER * MAX_CPUS_PER_CLUSTER
				* MSM_PC_NUM_COUNTERS
				* sizeof(*msm_pc_debug_counters);

	msm_pc_debug_counters = dma_alloc_coherent(&pdev->dev, alloc_size,
				&msm_pc_debug_counters_phys, GFP_KERNEL);

	if (msm_pc_debug_counters)
		memset(msm_pc_debug_counters, 0, alloc_size);
	else
		msm_pc_debug_counters_phys = 0;

	if (pdev->dev.of_node) {
		msm_pm_tz_flushes_cache =
			of_property_read_bool(pdev->dev.of_node,
					"qcom,tz-flushes-cache");

		msm_pm_ret_no_pll_switch =
			of_property_read_bool(pdev->dev.of_node,
					"qcom,no-pll-switch-for-retention");

		ret = msm_pm_clk_init(pdev);
		if (ret) {
			pr_info("msm_pm_clk_init returned error\n");
			return ret;
		}
	}

	return 0;
}

static struct of_device_id msm_cpu_pm_table[] = {
	{.compatible = "qcom,pm"},
	{},
};

static struct platform_driver msm_cpu_pm_driver = {
	.probe = msm_cpu_pm_probe,
	.driver = {
		.name = "msm-pm",
		.owner = THIS_MODULE,
		.of_match_table = msm_cpu_pm_table,
	},
};

static int __init msm_pm_debug_counters_init(void)
{
	return platform_driver_register(&msm_cpu_pm_driver);
}
fs_initcall(msm_pm_debug_counters_init);
