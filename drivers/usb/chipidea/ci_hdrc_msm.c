/* Copyright (c) 2010, Code Aurora Forum. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 and
 * only version 2 as published by the Free Software Foundation.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>
#include <linux/usb/msm_hsusb_hw.h>
#include <linux/usb/msm_hsusb.h>
#include <linux/usb/ulpi.h>
#include <linux/usb/gadget.h>
#include <linux/usb/chipidea.h>

#include "ci.h"

#define MSM_USB_BASE	(ci->hw_bank.abs)

static void ci_hdrc_msm_notify_event(struct ci_hdrc *ci, unsigned event)
{
	struct device *dev = ci->gadget.dev.parent;

	switch (event) {
	case CI_HDRC_CONTROLLER_RESET_EVENT:
		dev_dbg(dev, "CI_HDRC_CONTROLLER_RESET_EVENT received\n");
		writel(0, USB_AHBBURST);
		writel(0, USB_AHBMODE);
		usb_phy_init(ci->usb_phy);
		break;
	case CI_HDRC_CONTROLLER_STOPPED_EVENT:
		dev_dbg(dev, "CI_HDRC_CONTROLLER_STOPPED_EVENT received\n");
		/*
		 * Put the phy in non-driving mode. Otherwise host
		 * may not detect soft-disconnection.
		 */
		usb_phy_notify_disconnect(ci->usb_phy, USB_SPEED_UNKNOWN);
		break;
	default:
		dev_dbg(dev, "unknown ci_hdrc event\n");
		break;
	}
}

static struct ci_hdrc_platform_data ci_hdrc_msm_platdata = {
	.name			= "ci_hdrc_msm",
	.capoffset		= DEF_CAPOFFSET,
	.flags			= CI_HDRC_REGS_SHARED |
				  CI_HDRC_DISABLE_STREAMING,

	.notify_event		= ci_hdrc_msm_notify_event,
};

static int ci_hdrc_msm_probe(struct platform_device *pdev)
{
	struct platform_device *plat_ci;
	struct usb_phy *phy;

	phy = devm_usb_get_phy_by_phandle(&pdev->dev, "usb-phy", 0);
	if (IS_ERR(phy))
		return PTR_ERR(phy);

	ci_hdrc_msm_platdata.usb_phy = phy;

	/* Keep PHY out of low-power mode so hw_device_init can read regs */
	usb_phy_set_suspend(phy, 0);

	plat_ci = ci_hdrc_add_device(&pdev->dev,
				pdev->resource, pdev->num_resources,
				&ci_hdrc_msm_platdata);
	if (IS_ERR(plat_ci)) {
		dev_err(&pdev->dev, "ci_hdrc_add_device failed: %ld\n",
			PTR_ERR(plat_ci));
		return PTR_ERR(plat_ci);
	}

	dev_info(&pdev->dev, "ci_hdrc_msm probe OK\n");

	platform_set_drvdata(pdev, plat_ci);

	pm_runtime_no_callbacks(&pdev->dev);
	pm_runtime_enable(&pdev->dev);

	return 0;
}

static int ci_hdrc_msm_remove(struct platform_device *pdev)
{
	struct platform_device *plat_ci = platform_get_drvdata(pdev);

	pm_runtime_disable(&pdev->dev);
	ci_hdrc_remove_device(plat_ci);

	return 0;
}

static const struct of_device_id msm_ci_dt_match[] = {
	{ .compatible = "qcom,ci-hdrc", },
	{ }
};
MODULE_DEVICE_TABLE(of, msm_ci_dt_match);

static struct platform_driver ci_hdrc_msm_driver = {
	.probe = ci_hdrc_msm_probe,
	.remove = ci_hdrc_msm_remove,
	.driver = {
		.name = "msm_hsusb",
		.of_match_table = msm_ci_dt_match,
	},
};

module_platform_driver(ci_hdrc_msm_driver);

MODULE_ALIAS("platform:msm_hsusb");
MODULE_ALIAS("platform:ci13xxx_msm");
MODULE_LICENSE("GPL v2");

/*
 * Late diagnostic — print USB subsystem state after boot settles.
 */
static int __init bq268_usb_diag(void)
{
	struct usb_phy *phy;

	phy = usb_get_phy(USB_PHY_TYPE_USB2);
	if (IS_ERR(phy)) {
		pr_err("BQ268 USB: no PHY registered\n");
	} else {
		struct msm_otg *motg;
		u32 otgsc;

		motg = container_of(phy, struct msm_otg, phy);
		otgsc = readl(motg->regs + 0x01A4);

		pr_err("BQ268 USB: OTG=%s OTGSC=%08x\n",
		       usb_otg_state_string(phy->otg->state), otgsc);
		pr_err("  BSV=%d BSVIE=%d ID=%d IDIE=%d\n",
		       !!(otgsc & BIT(11)), !!(otgsc & BIT(27)),
		       !!(otgsc & BIT(8)),  !!(otgsc & BIT(24)));
		usb_put_phy(phy);
	}

	return 0;
}
late_initcall(bq268_usb_diag);
